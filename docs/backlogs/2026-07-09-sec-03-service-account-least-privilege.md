# SEC-03 - Bật cơ chế least-privilege cho service account

## 1. Mục tiêu

Mục tiêu của SEC-03 là giảm blast radius khi một pod, token hoặc workload identity bị compromise bằng cách đưa service account của workload về đúng nguyên tắc least-privilege.

Trong Kubernetes, service account là danh tính mà pod dùng để tương tác với Kubernetes API. Khi chạy trên EKS, service account còn có thể được gắn IAM role thông qua IRSA bằng annotation `eks.amazonaws.com/role-arn`. Nếu toàn bộ workload dùng chung một service account hoặc dùng service account có quyền rộng, một lỗi ở service ít quan trọng cũng có thể mở đường tới quyền của service quan trọng hơn.

SEC-03 vì vậy tập trung vào việc chuyển chart từ mô hình một service account chung sang mô hình có chủ đích hơn:

- Workload mặc định không có quyền AWS nếu không thật sự cần.
- Workload cần quyền đặc biệt được tách service account riêng.
- IRSA annotation chỉ gắn vào service account có nhu cầu AWS rõ ràng.
- Kubernetes RBAC được cấp theo hành vi cụ thể, không cấp rộng theo namespace.
- Không làm thay đổi luồng checkout, observability, `flagd` hoặc cấu hình deploy hiện tại nếu chỉ tạo backlog.

## 2. Tình trạng hiện tại

### 2.1. Chart đang có service account chung

Trong `tf2-corp-chart/values.yaml`, chart hiện có cấu hình service account ở mức global:

```yaml
serviceAccount:
  create: true
  annotations: {}
  name: ""
```

Ý nghĩa thực tế:

- `create: true`: chart sẽ tạo một Kubernetes ServiceAccount.
- `annotations: {}`: chưa có annotation nào, bao gồm chưa có IRSA role ARN.
- `name: ""`: nếu không override, tên service account được sinh từ helper của chart.

Template `tf2-corp-chart/templates/serviceaccount.yaml` render một service account từ cấu hình global này:

```yaml
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "techx-corp.serviceAccountName" . }}
  labels:
    {{- include "techx-corp.labels" . | nindent 4 }}
  {{- if .Values.serviceAccount.annotations }}
  annotations:
    {{- range $key, $value := .Values.serviceAccount.annotations }}
    {{- printf "%s: %s" $key (tpl $value $ | quote) | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end }}
```

Điểm tích cực là chart đã có sẵn chỗ để gắn annotation. Tuy nhiên chỗ này đang là global, nên nếu gắn một IAM role vào đây thì mọi workload dùng service account đó đều có cùng quyền.

### 2.2. Workload template đang dùng cùng service account

Trong `tf2-corp-chart/templates/component.yaml`, mỗi component nhận cùng cấu hình service account global:

```yaml
{{- $config := set . "serviceAccount" $.Values.serviceAccount }}
```

Trong `tf2-corp-chart/templates/_objects.tpl`, pod spec gán:

```yaml
serviceAccountName: {{ include "techx-corp.serviceAccountName" .}}
```

Điều này có nghĩa là các workload được render từ component template đang đi qua cùng helper `techx-corp.serviceAccountName`. Chart chưa có cấu hình kiểu `components.<component-name>.serviceAccount` để tách riêng danh tính theo từng service.

### 2.3. Infra đã có nền tảng IRSA, nhưng app workload chưa được tách quyền

Trong `tf2-corp-infra`, EKS module đã có phần OIDC/IRSA cho AWS Load Balancer Controller:

- Có OIDC issuer/output.
- Có IAM role cho AWS Load Balancer Controller.
- Có Helm command mẫu dùng annotation `eks.amazonaws.com/role-arn`.
- `variables.tf` có mô hình `service_account_role_arn` cho addon cần quyền IAM.

Điều này chứng minh hạ tầng đã đi theo hướng IRSA cho add-on cấp cluster. Tuy nhiên ở chart ứng dụng, các service như `checkout`, `accounting`, `fraud-detection`, `frontend`, `payment`, `cart`, `kafka`, `postgresql`, `valkey-cart` vẫn chưa có service account riêng theo nhu cầu quyền.

## 3. Rủi ro kỹ thuật và business

### 3.1. Rủi ro kỹ thuật

Nếu toàn bộ workload dùng một service account chung:

- Không phân biệt được service nào thật sự cần quyền Kubernetes API hoặc AWS API.
- Nếu một pod bị chiếm quyền, attacker có thể dùng token của service account chung.
- Nếu sau này gắn IRSA role vào service account global, quyền AWS đó sẽ lan sang tất cả workload dùng chung service account.
- Khó audit vì CloudTrail hoặc Kubernetes audit log chỉ thấy một danh tính chung thay vì service cụ thể.
- Khó áp chính sách khác nhau cho customer-facing services, data services và observability services.

Trong hệ thống TechX Corp, các service có mức nhạy cảm khác nhau. Ví dụ:

- `frontend` và `frontend-proxy` là customer-facing, không nên có quyền AWS/Kubernetes đặc biệt.
- `checkout`, `payment`, `cart`, `product-catalog` nằm trong luồng doanh thu, cần hạn chế blast radius rất chặt.
- `accounting` và `fraud-detection` xử lý dữ liệu tài chính/event, cần audit rõ hơn nếu sau này có quyền đọc/ghi external service.
- `opentelemetry-collector` có thể cần quyền quan sát cluster, nhưng quyền này không nên bị chia sẻ với app service bình thường.

### 3.2. Tác động business

Nếu một service ít quan trọng bị compromise nhưng dùng cùng danh tính với workload quan trọng hơn, sự cố có thể lan từ lỗi kỹ thuật thành incident ảnh hưởng doanh thu hoặc dữ liệu tài chính.

Tác động business chính:

- Giảm nguy cơ attacker mở rộng quyền từ một pod sang nhiều phần của hệ thống.
- Tăng khả năng khoanh vùng incident theo service.
- Làm audit dễ giải thích hơn với CFO, SRE lead và mentor.
- Tạo nền tảng an toàn trước khi hệ thống mở rộng sang nhiều môi trường hoặc nhiều AWS integration hơn.

## 4. Phương án kỹ thuật đề xuất

SEC-03 chưa nên gắn một IAM role global vào `serviceAccount.annotations`. Hướng đúng là tách danh tính theo workload group, sau đó mới gắn quyền cụ thể cho từng nhóm.

### 4.1. Phân loại workload theo nhu cầu quyền

Đề xuất bắt đầu bằng bảng phân loại:

| Nhóm workload | Ví dụ service | Nhu cầu quyền mặc định |
| --- | --- | --- |
| Customer-facing | `frontend`, `frontend-proxy` | Không cần quyền AWS/K8s đặc biệt |
| Revenue path | `checkout`, `payment`, `cart`, `product-catalog`, `shipping` | Không gắn AWS role nếu chưa có nhu cầu rõ ràng |
| Event/data processing | `accounting`, `fraud-detection` | Chỉ gắn role riêng nếu cần truy cập AWS managed service |
| Data plane nội bộ | `kafka`, `postgresql`, `valkey-cart` | Không dùng IRSA mặc định |
| Observability | `opentelemetry-collector`, `grafana`, `prometheus`, `jaeger`, `opensearch` | Tách quyền quan sát khỏi quyền app |
| Platform add-on | AWS Load Balancer Controller | Đã có IRSA riêng trong infra |

Nguyên tắc: chỉ service có nhu cầu thực tế mới được cấp quyền. Không cấp trước "để tiện".

### 4.2. Mở rộng chart để hỗ trợ service account theo component

Khi implement SEC-03, chart nên hỗ trợ cấu hình ở mức component, ví dụ:

```yaml
components:
  accounting:
    serviceAccount:
      create: true
      name: accounting
      annotations: {}

  fraud-detection:
    serviceAccount:
      create: true
      name: fraud-detection
      annotations: {}
```

Global `serviceAccount` vẫn giữ để tương thích ngược:

```yaml
serviceAccount:
  create: true
  annotations: {}
  name: ""
```

Quy tắc fallback đề xuất:

- Nếu component có `serviceAccount`, dùng service account riêng của component.
- Nếu component không cấu hình, dùng global service account hiện tại.
- Không tự động gắn annotation IRSA từ global xuống component trừ khi được khai báo rõ.

### 4.3. Tách service account cho workload quan trọng

Đề xuất nhóm service account ban đầu:

- `techx-corp-default`: workload không cần quyền đặc biệt.
- `techx-corp-checkout`: checkout path nếu sau này cần AWS integration riêng.
- `techx-corp-accounting`: xử lý dữ liệu tài chính/event.
- `techx-corp-fraud-detection`: xử lý fraud event.
- `techx-corp-observability`: chỉ cho thành phần cần quyền quan sát cluster, nếu có.

Không nhất thiết tạo quá nhiều service account ngay từ ngày đầu. Mục tiêu là tách những nhóm có rủi ro khác nhau để giảm blast radius mà không làm chart quá phức tạp.

### 4.4. Gắn IRSA theo least-privilege khi chạy trên EKS

Nếu một service thật sự cần gọi AWS API, tạo IAM role riêng cho service đó và gắn annotation:

```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/<role-name>
```

Role trust policy phải giới hạn theo namespace và service account cụ thể, ví dụ về mặt nguyên tắc:

```text
system:serviceaccount:<namespace>:techx-corp-accounting
```

Không dùng wildcard rộng kiểu:

```text
system:serviceaccount:<namespace>:*
```

IAM policy cũng cần theo hành động tối thiểu, ví dụ:

- Nếu service chỉ đọc một queue/topic/secret cụ thể, chỉ cấp quyền đọc đúng resource đó.
- Không dùng `*` resource nếu có thể giới hạn ARN.
- Không reuse role của AWS Load Balancer Controller cho app workload.

### 4.5. Kubernetes RBAC nếu workload cần gọi Kubernetes API

Hiện tại app workload bình thường không nên cần gọi Kubernetes API. Nếu có nhu cầu, tạo `Role`/`RoleBinding` riêng theo namespace thay vì `ClusterRoleBinding` rộng.

Ví dụ hướng triển khai:

- Workload chỉ cần đọc ConfigMap cụ thể: cấp `get` trên ConfigMap đó.
- Workload cần list pod để discovery: xem lại thiết kế trước, vì thường app không nên cần quyền này.
- Observability component cần metadata cluster: tách quyền này khỏi app service.

## 5. Kiểm tra trước deploy

Trước khi implement SEC-03 vào chart, cần render và kiểm tra behavior hiện tại để có baseline:

```powershell
helm template techx-corp . -n <namespace>
```

Cần xác nhận baseline:

- Có một `ServiceAccount` được render từ `templates/serviceaccount.yaml`.
- Các workload component dùng cùng `serviceAccountName`.
- `serviceAccount.annotations` đang rỗng nếu không override.
- Không có `eks.amazonaws.com/role-arn` bị gắn nhầm vào app workload.

Sau khi implement trong tương lai, render cần xác nhận:

- Component được cấu hình riêng có service account riêng.
- Component không cấu hình riêng vẫn dùng fallback global.
- Chỉ service account được chỉ định mới có annotation IRSA.
- Không có app workload customer-facing nhận quyền AWS ngoài ý muốn.

## 6. Deploy và verify

Khi SEC-03 được implement trong chart, deploy bằng Helm:

```powershell
helm upgrade --install techx-corp . -n <namespace>
```

Verify service account:

```powershell
kubectl -n <namespace> get serviceaccount
kubectl -n <namespace> describe serviceaccount <service-account-name>
kubectl -n <namespace> get pods -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName
```

Verify IRSA nếu có gắn role:

```powershell
kubectl -n <namespace> describe serviceaccount <service-account-name>
```

Cần thấy annotation `eks.amazonaws.com/role-arn` chỉ nằm trên service account được cấp quyền.

Verify workload vẫn chạy:

```powershell
kubectl -n <namespace> get pods
kubectl -n <namespace> logs deploy/checkout
kubectl -n <namespace> logs deploy/frontend-proxy
```

Kiểm tra hành vi nghiệp vụ:

- Storefront vẫn truy cập được.
- Checkout path vẫn hoạt động.
- `accounting` và `fraud-detection` vẫn consume Kafka như trước.
- Observability vẫn nhận metrics/traces/logs.
- `flagd` vẫn giữ cơ chế incident, không bị tắt hoặc đổi hướng.

### 6.1. Ghi evidence để pitch

Evidence nên gồm:

- Diff values/template thể hiện service account tách theo component.
- Output `helm template` chứng minh chỉ service account cần thiết có IRSA annotation.
- Output `kubectl get pods -o custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName`.
- Output `kubectl describe serviceaccount` cho workload có quyền và workload không có quyền.
- Screenshot/log chứng minh checkout path và observability vẫn hoạt động.

## 7. Acceptance Criteria

SEC-03 được xem là hoàn thành khi đạt các điều kiện sau:

- Chart hỗ trợ service account riêng theo component hoặc theo nhóm workload quan trọng.
- Global service account vẫn hoạt động để giữ tương thích ngược.
- Workload không cần quyền AWS/K8s đặc biệt không được gắn IRSA role.
- IRSA annotation chỉ xuất hiện ở service account được chỉ định rõ.
- Không có IAM role dùng chung cho toàn bộ app workload.
- Trust policy của IAM role giới hạn theo namespace và service account cụ thể.
- Kubernetes RBAC, nếu có, được cấp theo `Role`/`RoleBinding` tối thiểu.
- `checkout`, `frontend`, `frontend-proxy`, `accounting`, `fraud-detection` vẫn chạy ổn sau deploy.
- Không làm thay đổi cơ chế incident của `flagd`.
- Có evidence đủ để mentor kiểm tra bằng `helm template` và `kubectl`.

## 8. Rollback plan

Nếu deploy SEC-03 làm pod không lên hoặc service mất quyền cần thiết:

1. Kiểm tra pod đang dùng service account nào:

   ```powershell
   kubectl -n <namespace> get pod <pod-name> -o jsonpath="{.spec.serviceAccountName}"
   ```

2. Kiểm tra service account và annotation:

   ```powershell
   kubectl -n <namespace> describe serviceaccount <service-account-name>
   ```

3. Kiểm tra log pod để xác định lỗi quyền, lỗi AWS credential hoặc lỗi Kubernetes API.

4. Nếu lỗi chỉ do thiếu annotation/role, sửa đúng service account rồi `helm upgrade` lại.

5. Nếu cần phục hồi nhanh, dùng Helm rollback:

   ```powershell
   helm rollback techx-corp <revision> -n <namespace>
   ```

Không chọn rollback lâu dài về một service account có quyền rộng cho toàn bộ workload. Nếu phải rollback tạm thời để khôi phục dịch vụ, cần ghi decision log và tạo follow-up để tách quyền lại ngay sau khi ổn định.

## 9. Pitching

### Vấn đề

SEC-03 xử lý một rủi ro nền tảng: danh tính của pod. Hiện chart đã tạo service account, nhưng chưa có mô hình phân quyền tách riêng theo component. Khi hệ thống mở rộng hoặc bắt đầu gắn quyền AWS qua IRSA, nếu vẫn dùng một service account chung thì quyền của một service có thể lan sang nhiều service khác.

Thay đổi này không tạo feature mới cho khách hàng, nhưng làm hệ thống an toàn hơn khi có sự cố. Nếu một pod bị compromise, attacker chỉ lấy được quyền của đúng workload đó, thay vì quyền chung của cả namespace.

### Role PM

**Mentor hỏi:** Khách hàng được gì từ việc tách service account?

**Trả lời:** Khách hàng được bảo vệ gián tiếp. Khi một service gặp lỗi bảo mật, hệ thống có khả năng khoanh vùng tốt hơn, giảm xác suất incident lan sang checkout, dữ liệu đơn hàng hoặc dữ liệu tài chính. Đây là phần khó thấy trên UI nhưng rất quan trọng để giữ niềm tin và độ ổn định dịch vụ.

### Role CFO

**Mentor hỏi:** Việc này có làm tăng chi phí không?

**Trả lời:** Chi phí hạ tầng gần như không tăng. Đây chủ yếu là thay đổi cấu hình Helm, Kubernetes service account và IAM policy nếu có IRSA. Lợi ích là giảm rủi ro breach lan rộng và giúp audit rõ hơn. ROI tốt vì không cần thêm node hay managed service mới.

### Role SRE lead

**Mentor hỏi:** Có làm rủi ro deploy tăng không?

**Trả lời:** Có rủi ro nếu tách quyền sai làm pod thiếu permission, nên rollout cần bắt đầu bằng render/dry-run và áp dụng theo nhóm workload. Global service account nên được giữ làm fallback để rollback nhanh. Acceptance criteria yêu cầu verify `serviceAccountName` của pod, annotation IRSA và luồng checkout sau deploy.

### Rollback

**Mentor hỏi:** Nếu tách service account xong app lỗi quyền thì sao?

**Trả lời:** Kiểm tra pod đang dùng service account nào, kiểm tra annotation/role, rồi sửa đúng service account hoặc rollback Helm revision. Vì thay đổi nằm ở identity layer, có thể phục hồi nhanh bằng rollback chart mà không cần đổi code app. Sau rollback tạm thời, team vẫn cần follow-up để không quay lại mô hình quyền rộng lâu dài.
