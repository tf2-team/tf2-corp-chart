# Backlog: SEC-04 - Chuẩn hóa pod/container security context (Helm chart level)

## Bối cảnh
Để nâng cao mức độ bảo mật cho hệ thống TechX Corp Platform theo tiêu chuẩn Pod Security Standards (Restricted profile), Helm chart `techx-corp-chart` cần triển khai chuẩn hóa cấu hình bảo mật Security Context cho Pod và Container một cách tự động và thống nhất cho tất cả các microservices.

## Vấn đề
Hiện tại, Helm chart áp dụng cơ chế ghi đè hoàn toàn (override) thay vì kết hợp (merge) cấu hình từ mặc định (`default.securityContext`). Điều này khiến cho các component đã có cấu hình tùy biến (ví dụ như chỉ định `runAsUser` đặc thù) không tự động nhận diện được các thiết lập bảo mật baseline mới (như `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, và `capabilities.drop: ["ALL"]`). Hơn nữa, việc bật hệ thống tập tin read-only đòi hỏi phải cấu hình thêm các ổ đĩa ghi tạm thời (`emptyDir` cho `/tmp`) để tránh lỗi crash runtime.

## Giải pháp đề xuất
1. Định nghĩa baseline bảo mật mặc định trong `techx-corp-chart/values.yaml` dưới các khóa:
   - `default.podSecurityContext.seccompProfile.type: RuntimeDefault`
   - `default.securityContext.runAsNonRoot: true`
   - `default.securityContext.allowPrivilegeEscalation: false`
   - `default.securityContext.readOnlyRootFilesystem: true`
   - `default.securityContext.capabilities.drop: ["ALL"]`
   - `default.initContainerSecurityContext` (có cùng container baseline cấu hình và chạy với UID/GID 10001:10001 để tránh lỗi runAsNonRoot của image busybox).
2. Cập nhật template Helm (`templates/_objects.tpl`) dùng hàm `mergeOverwrite` để kết hợp các cấu hình mặc định (default values) với các tùy biến cục bộ (component-level overrides) cho container chính, sidecars, và init containers.
3. Thêm các volume ghi tạm thời (`mountedEmptyDirs` cho `/tmp`) trong file values cho các runtime (JVM, Python, Node, Ruby) khi thực thi.
4. Cấu hình các subchart giám sát (OTel Collector, Prometheus, Grafana, Jaeger) qua giá trị values mà không chỉnh sửa tệp nén subchart gốc.
5. Cập nhật `values.schema.json` để bổ sung kiểm tra kiểu dữ liệu của các trường cấu hình Security Context.
6. Thiết lập các ngoại lệ đã được ghi nhận như `postgresql`, `kafka`, `valkey-cart`, và `opensearch` chạy với `readOnlyRootFilesystem: false`.

## Acceptance Criteria
- Chạy lệnh `helm lint` trên thư mục chart thành công mà không gặp lỗi nào.
- Render manifest của tất cả các ứng dụng chính (app workloads) thông qua `helm template` hiển thị đầy đủ các cấu hình:
  - `runAsNonRoot: true`
  - `allowPrivilegeEscalation: false`
  - `capabilities.drop: ["ALL"]`
  - `seccompProfile.type: RuntimeDefault`
- Không có bất kỳ workload nào chứa cấu hình `privileged: true` hoặc chạy dưới quyền root (`runAsUser: 0`).
- Các ngoại lệ chạy hệ thống tập tin writable (`readOnlyRootFilesystem: false`) chỉ được giới hạn ở các dịch vụ lưu trữ trạng thái (`postgresql`, `kafka`, `valkey-cart`, `opensearch`) và được ghi chú rõ ràng trong tài liệu.

## Kiểm thử / xác minh
1. Kiểm thử cú pháp Helm:
   ```sh
   helm lint techx-corp-chart
   ```
2. Tạo manifest để kiểm tra cấu hình bảo mật được render thực tế:
   ```sh
   helm template sec04 techx-corp-chart --namespace techx-corp
   ```
   Xác minh các khối `securityContext` ở cấp pod và container có đầy đủ các trường cấu hình baseline và merge chính xác.

## Rủi ro & rollback
- **Rủi ro**: Lỗi logic merge có thể làm mất cấu hình `runAsUser` đặc thù của một số ứng dụng (envoy proxy, php, postgres, v.v.), dẫn đến container không thể khởi chạy do sai quyền sở hữu file.
- **Rollback**: Gỡ cấu hình baseline tại `default.securityContext` và `default.podSecurityContext` trong file `values.yaml` về dạng `{}` để đưa hệ thống về trạng thái ban đầu.

---

## English Summary
This backlog tracks the Helm-level implementation for standardizing Pod and Container Security Contexts within the `techx-corp-chart` repository. It involves defining global hardening baselines (`runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`), updating templates to recursively merge default values with local overrides, setting up writable `/tmp` emptyDir mounts for read-only root filesystems, configuring observability subcharts, updating JSON schemas, and enforcing validated exceptions for stateful workloads.
