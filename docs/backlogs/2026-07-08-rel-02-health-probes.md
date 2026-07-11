# [W1][REL-02] Backlog và ghi chú quyết định về readiness/liveness probe

Trạng thái: Đã bổ sung probe cho các service xử lý request và dependency trọng yếu; 2026-07-11 đóng gap recommendation/image-provider/llm, thêm liveness + threshold tiers (`docs/operations/probe-thresholds.md`). Cần follow-up riêng cho background worker.  
Owner: CDO - Security & Reliability  
Pillars: Reliability, Security, Operational Excellence  
Cập nhật lần cuối: 2026-07-11

## 1. Vấn đề cần giải quyết

Một số workload trong TechX Corp chart trước đây chưa có `readinessProbe` và `livenessProbe` rõ ràng. Khi thiếu probe, Kubernetes không thể:

- tự động restart pod khi process vẫn chạy nhưng ứng dụng đã mất khả năng phục vụ;
- ngừng route traffic vào pod chưa sẵn sàng nhận request;
- quan sát và giải thích hành vi rollout một cách rõ ràng khi có incident.

Rủi ro này ảnh hưởng trực tiếp đến các luồng quan trọng như frontend, checkout, cart, product catalog, payment, recommendation, datastore và ingress path.

## 2. Tác động business

| Rủi ro | Tác động |
|---|---|
| Pod lỗi vẫn nằm trong service endpoint | User gặp lỗi cho đến khi có can thiệp thủ công |
| Pod nhận traffic trước khi sẵn sàng | Checkout/cart/product flow lỗi trong rollout |
| Dependency khởi động chậm bị restart quá sớm | Restart storm, tăng MTTR |
| Worker bị loại trừ nhưng không có ghi chú | Reviewer có thể hiểu nhầm là thiếu sót implementation |

## 3. Phạm vi

### Trong phạm vi

Bổ sung `livenessProbe` và `readinessProbe` cho các component có network port ổn định hoặc là dependency quan trọng.

Application service:

- `ad`
- `cart`
- `checkout`
- `currency`
- `email`
- `frontend`
- `frontend-proxy`
- `image-provider`
- `payment`
- `product-catalog`
- `product-reviews`
- `quote`
- `recommendation`
- `shipping`

Dependency và platform component:

- `flagd`
- `kafka`
- `llm`
- `postgresql`
- `valkey-cart`

### Ngoài phạm vi của task hiện tại

| Component | Lý do loại trừ | Follow-up |
|---|---|---|
| `accounting` | Đây là Kafka background worker, không expose HTTP/gRPC/TCP listener ổn định để probe qua network | Tạo health endpoint hoặc exec probe có ý nghĩa riêng cho worker |
| `fraud-detection` | Đây là Kafka background worker, chạy consume loop liên tục và không có Service port để readiness gate traffic | Tạo health endpoint hoặc exec probe có ý nghĩa riêng cho worker |
| `load-generator` | Thành phần tạo tải/non-prod, không nằm trong critical serving path | Chỉ bật probe nếu môi trường benchmark/chaos yêu cầu |

## 4. Quyết định kỹ thuật

| Loại workload | Cách probe | Lý do |
|---|---|---|
| HTTP service | `httpGet` | Kiểm tra đúng endpoint ứng dụng nếu có health path |
| gRPC service | `grpc` | Phù hợp với service expose gRPC port |
| Dependency không có health endpoint riêng | `tcpSocket` | Xác minh port đang accept connection, tránh fake HTTP endpoint |
| Background worker | Chưa thêm network probe | Worker không nhận request trực tiếp; cần app-level health riêng |

Probe được cấu hình trong `values.yaml` và render thông qua template chung trong `_objects.tpl`, vì vậy không cần viết duplicate manifest cho từng service.

## 5. Giải thích riêng cho `accounting` và `fraud-detection`

### `accounting`

`accounting` là worker đọc message từ Kafka. Ứng dụng khởi động consumer bằng `StartListening()` và chạy host process, nhưng chart không có `service.port`/`ports` ổn định để Kubernetes probe qua network.

Nếu thêm `tcpSocket` hoặc `httpGet` giả lập vào worker này, probe sẽ không phản ánh đúng tình trạng business. Readiness cũng không có tác dụng gate traffic vì worker không nằm sau Kubernetes Service nhận request từ user.

### `fraud-detection`

`fraud-detection` cũng là Kafka consumer worker. Lỗi quan trọng cần phát hiện là worker có đang consume được topic, kết nối Kafka có ổn định, và loop xử lý có bị treo hay không. Nhưng các tín hiệu này không thể đo đúng bằng network probe nếu ứng dụng không expose health endpoint.

Việc loại trừ trong REL-02 là có chủ ý, không phải bỏ sót. Hai worker này nên được tách thành backlog follow-up để thiết kế health check đúng nghĩa.

## 6. Acceptance criteria cho REL-02

Task REL-02 được xem là đạt khi:

- các service xử lý request quan trọng có `readinessProbe` và `livenessProbe`;
- dependency quan trọng có probe phù hợp với khả năng expose port;
- `values.schema.json` chấp nhận các kiểu probe đang dùng: `httpGet`, `grpc`, `tcpSocket`;
- các component bị loại trừ có lý do rõ ràng trong backlog/documentation;
- chart render được probe vào container chính và sidecar nếu có cấu hình;
- rollout không bị restart loop do probe quá aggressive.

## 7. Kế hoạch validate

Chạy validate chart:

```powershell
helm lint .
helm template techx . > rendered.yaml
```

Khi deploy lên cluster:

```bash
kubectl get pods -n <namespace>
kubectl describe pod -n <namespace> <pod-name>
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

Cần kiểm tra thêm:

- pod mới rollout có `READY` đúng như kỳ vọng;
- không có event `Readiness probe failed` lặp lại bất thường;
- không có `CrashLoopBackOff` do liveness probe quá ngắn;
- các service critical không nhận traffic trước khi ready.

## 8. Rollback plan

Nếu probe gây restart loop hoặc rollout fail:

1. Tăng `initialDelaySeconds`, `timeoutSeconds` hoặc `failureThreshold` cho service bị ảnh hưởng.
2. Tạm thời disable probe ở service đó bằng values override nếu chart hỗ trợ.
3. Rollback Helm release về revision trước.
4. Ghi lại service, event và thời điểm lỗi để điều chỉnh probe threshold.

## 9. Follow-up backlog

| ID | Priority | Nội dung | Kết quả mong đợi |
|---|---|---|---|
| REL-02-FU-01 | P1 | Thiết kế health check thật cho `accounting` worker | Worker có readiness/liveness dựa trên Kafka consumer loop và dependency |
| REL-02-FU-02 | P1 | Thiết kế health check thật cho `fraud-detection` worker | Worker có tín hiệu health phản ánh khả năng consume và xử lý message |
| REL-02-FU-03 | P2 | Quyết định probe policy cho `load-generator` | Có cấu hình riêng cho non-prod/benchmark nếu cần |
| REL-02-FU-04 | P2 | Cập nhật README của chart về probe policy | Reviewer và operator biết cách thêm/sửa probe sau này |

## 10. Câu hỏi reviewer thường gặp

### Vì sao không thêm probe cho tất cả component?

Probe chỉ nên đo tín hiệu health có ý nghĩa. Với background worker không expose port, network probe có thể tạo cảm giác an toàn giả. Cần thiết kế health endpoint hoặc exec probe riêng.

### Vì sao có service dùng `tcpSocket` thay vì HTTP?

Một số dependency chỉ cần xác nhận port sẵn sàng nhận kết nối, không có HTTP health endpoint. `tcpSocket` phù hợp hơn trong trường hợp đó.

### Việc này có làm thay đổi logic business không?

Không. Thay đổi nằm ở tầng Kubernetes chart và cách kubelet đánh giá health của pod. Business code không bị thay đổi trong REL-02.

### Rủi ro còn lại là gì?

Hai Kafka worker (`accounting`, `fraud-detection`) vẫn cần health check đúng nghĩa ở tầng ứng dụng. Đây là follow-up P1 vì có liên quan đến reliability của background processing, nhưng không nên làm bằng network probe giả lập trong task này.
