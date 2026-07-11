# Backlog: REL-06 - Chuẩn hóa resource requests/limits và bỏ các cấu hình quá sát mép (Helm chart level)

## Bối cảnh
Để đảm bảo TechX Corp Platform vận hành ổn định trên cụm EKS dưới các điều kiện tải biến động, việc quản lý và lập lịch tài nguyên (Resource Scheduling) đóng vai trò then chốt. Cấu hình đúng Resource Requests và Limits giúp Kubernetes Scheduler phân bổ Pods hợp lý lên các Node, đồng thời tránh lãng phí chi phí (ràng buộc ngân sách ~$300/tuần) và giữ vững cam kết chất lượng dịch vụ (SLO).

## Vấn đề
Hiện tại, cấu hình tài nguyên của các microservices trong Helm chart `techx-corp-chart` đang gặp các hạn chế lớn:
1. **Thiếu cấu hình `requests`:** Hầu hết các service trong file `values.yaml` chỉ định nghĩa `limits` mà không cấu hình `requests` tương ứng. Điều này khiến Scheduler không có căn cứ tối ưu để lập lịch, dễ dẫn đến tình trạng tranh chấp hoặc overprovisioning tài nguyên trên các Node.
2. **Cấu hình giới hạn quá sát mép (Under-provisioning):** Một số dịch vụ quan trọng (như `checkout`, `currency`, `shipping`, `product-catalog` và `valkey-cart`) đang có `limits.memory` cực kỳ thấp (`20Mi` ~ 20.9 MB). Thực tế đo đạc ở mức tải nền rất nhẹ (10 users), Pod `checkout` đã tiêu thụ tới `14.4 MB` (~70% limit). Khi tải tăng nhẹ hoặc khi runtime kích hoạt Garbage Collection, các Pod này sẽ lập tức vượt ngưỡng `20Mi` và bị hệ điều hành giết với lỗi `OOMKilled`.

## Tiêu chuẩn thiết lập Resource Request & Limit
Để tối ưu hóa hiệu năng và chi phí, tài nguyên của các thành phần trong hệ thống được chuẩn hóa theo các tiêu chuẩn QoS (Quality of Service) sau:

### A. Nhóm Dịch vụ Stateful / Database (`postgresql`, `kafka`, `valkey-cart`)
* **Tiêu chuẩn:** Thiết lập **Guaranteed QoS** (`Request = Limit`).
* **Lý do:** Đây là các dịch vụ lưu trữ trạng thái quan trọng, cần đảm bảo tính sẵn sàng tối đa và không bao giờ bị Kubernetes trục xuất (Evicted) khi Node thiếu tài nguyên.
* **Cấu hình đề xuất:**
  * `requests.memory` = `limits.memory`
  * `requests.cpu` = `limits.cpu`

### B. Nhóm Dịch vụ Stateless / Web App (`checkout`, `frontend`, `payment`, `product-catalog`,...)
* **Tiêu chuẩn:** Thiết lập **Burstable QoS** (`Request < Limit`).
* **Cấu hình CPU:**
  * **CPU Request:** Đặt bằng mức tiêu thụ trung bình (average usage) khi hệ thống chạy ở mức tải bình thường.
  * **CPU Limit:** Đặt gấp **1.5x - 3x** so với Request để cho phép ứng dụng bứt phá (burst) xử lý các tác vụ đột biến mà không bị nghẽn hiệu năng (CPU Throttling).
* **Cấu hình Memory:**
  * **Memory Request:** Đặt bằng lượng RAM thực tế ứng dụng cần sau khi khởi chạy hoàn tất ở tải nền (baseline usage) cộng thêm **10-20% buffer**.
  * **Memory Limit:** Đặt gấp **1.2x - 2x** so với Request để làm khoảng trống an toàn. Giới hạn tối thiểu cho các service nhẹ (Go/Rust/C++) là **`64Mi` - `128Mi`** (thay vì `20Mi` như trước) và các service nặng (JVM/Python/Node.js) là **`256Mi` - `512Mi`**.

### C. Đơn vị CPU (m) và Lý do phân bổ khác biệt giữa các dịch vụ
* **Đơn vị `m` (Millicores):**
  * Trong Kubernetes, tài nguyên CPU được phân phối theo đơn vị Cores. $1\text{ Core CPU}$ (vCPU) tương đương với `1000m` (millicores).
  * Ví dụ: `100m` tương ứng với $0.1\text{ Core}$ ($10\%$ hiệu năng của 1 nhân CPU), `300m` tương ứng với $0.3\text{ Core}$ ($30\%$ hiệu năng). Sử dụng đơn vị này giúp biểu diễn cấu hình tài nguyên nhỏ một cách trực quan mà không cần dùng số thập phân.
* **Lý do cấu hình khác biệt giữa các dịch vụ:**
  * **Đặc thù ngôn ngữ/môi trường chạy (Runtime):** Các dịch vụ viết bằng ngôn ngữ biên dịch trực tiếp (Native) như Go (`checkout`, `product-catalog`), Rust (`shipping`), C++ (`currency`) tối ưu CPU rất tốt, chỉ cần đặt CPU Request từ `20m` - `50m`. Trong khi đó, các dịch vụ chạy trên JVM hoặc có cơ chế dọn rác/JIT động như Java (`ad`), .NET (`cart`), Python/Node.js (`payment`, `product-reviews`) tiêu tốn nhiều chu kỳ CPU hơn, cần đặt tối thiểu từ `100m` - `300m`.
  * **Tính chất của luồng công việc (Workload):** Các helper service chỉ tính toán logic đơn giản (`currency`, `shipping`) cần rất ít CPU so với các gateway, service điều phối trung tâm (`checkout`), hoặc các collector telemetry (`otel-collector`) liên tục nhận hàng vạn records trace/metrics mỗi giây.

## Giải pháp đề xuất
1. Bổ sung cấu hình `requests` đầy đủ cho cả CPU và Memory của tất cả các microservices trong [values.yaml](../../values.yaml).
2. Điều chỉnh nâng các cấu hình `limits.memory` quá thấp (từ `20Mi` lên mức an toàn hơn như `128Mi` cho `checkout`, `currency`, `shipping`, `product-catalog` và `valkey-cart`).
3. Chuẩn hóa tỷ lệ giữa Request và Limit theo tiêu chuẩn đề ra cho từng nhóm dịch vụ.
4. Đảm bảo chạy test tải lớn (Stress Test) trên Locust bằng cách cấu hình `LOCUST_BROWSER_TRAFFIC_ENABLED` thành `"false"` trong values của `load-generator` để tránh Playwright ngốn sạch tài nguyên của máy giả lập.

## Acceptance Criteria
* Chạy lệnh `helm lint` trên thư mục chart thành công mà không gặp lỗi cú pháp nào.
* Khi render manifest (`helm template`), toàn bộ các workload microservices đều hiển thị đầy đủ cả hai khối cấu hình `requests` và `limits` cho cả CPU và Memory.
* Không còn microservice nào chạy với giới hạn Memory dưới **`64Mi`** (loại bỏ hoàn toàn cấu hình sát mép `20Mi`).
* Trong quá trình load test (với 50+ users trên Locust), không có Pod nào bị restart do lỗi `OOMKilled` và tỷ lệ CPU Throttling đo được trên Grafana dưới $10\%$.

## Kiểm thử / xác minh
1. **Kiểm tra cú pháp Helm:**
   ```sh
   helm lint .
   ```
2. **Kiểm tra manifest render thực tế:**
   ```sh
   helm template rel06 . --namespace techx-corp
   ```
   Xác minh các khối `resources.requests` và `resources.limits` được hiển thị đầy đủ và chính xác cho từng Pod.
3. **Kiểm thử tải lớn (Stress Test):**
   * Sửa cấu hình `LOCUST_USERS` thành `50` và `LOCUST_BROWSER_TRAFFIC_ENABLED` thành `"false"` trong values của `load-generator` rồi deploy.
   * Quan sát trên Grafana Dashboard xem RAM của các service có vượt ngưỡng an toàn và CPU có bị throttle hay không.

## Rủi ro & rollback
* **Rủi ro:** Việc tăng đồng loạt các cấu hình `requests` có thể khiến tổng tài nguyên yêu cầu vượt quá dung lượng thực tế của các EKS Node, dẫn đến các Pod mới không thể lập lịch (trạng thái `Pending` do *Insufficient CPU/Memory*).
* **Rollback:** Khôi phục cấu hình tài nguyên của các service trong tệp `values.yaml` về phiên bản cũ và chạy lại `helm upgrade`.

---

## English Summary
This backlog tracks the Helm-level implementation for standardizing resource requests and limits within `techx-corp-chart`. It involves specifying resource requests (currently missing for most services) and adjusting tight memory limits (upgrading `20Mi` settings to a safer buffer like `128Mi` for `checkout`, `currency`, `shipping`, `product-catalog`, and `valkey-cart`). It establishes QoS standards (Guaranteed for stateful workloads, Burstable for stateless workloads), updates resource templates, verifies the rendered configurations, and outlines risk mitigation plans to prevent scheduling failures on node capacity exhaustion.

## Source
Ported from [tf2-corp-chart PR #11](https://github.com/tmcmanhcuong/tf2-corp-chart/pull/11).
