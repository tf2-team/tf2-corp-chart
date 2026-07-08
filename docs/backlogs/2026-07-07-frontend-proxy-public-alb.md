# Backlog: Public ALB Ingress cho frontend-proxy

## Bối cảnh
Hệ thống TechX Corp cần mở public kết nối tới storefront nhưng phải bảo vệ tối đa các giao diện quản trị và endpoint đo lường (telemetry) nhạy cảm. Helm chart hiện có cấu trúc tổng quát để tạo Ingress chung nhưng chưa hỗ trợ cơ chế tùy chỉnh chuyên biệt để cấu hình AWS Application Load Balancer (ALB) cho `frontend-proxy`.

## Vấn đề
Hiện tại, cấu hình Ingress mặc định của chart không hỗ trợ các tính năng cụ thể của AWS ALB như chặn subpath bằng fixed-response 403, cấu hình target-type, hoặc cơ chế chỉ định lớp Ingress (ingressClassName). Nếu dùng chung Ingress tổng quát, chúng ta sẽ vô tình expose toàn bộ các route nhạy cảm như Grafana, Jaeger, hay các endpoint cấu hình cờ tính năng (feature flags) ra internet.

## Giải pháp đề xuất
Phát triển một cơ chế opt-in Ingress chuyên dụng cho `frontend-proxy` trong Helm chart:
1. Thêm giao diện cấu hình mới trong `values.yaml` dưới dạng `components.frontend-proxy.publicAlb` với trạng thái mặc định là disabled (`enabled: false`).
2. Cấu hình các giá trị mặc định bao gồm `ingressClassName: alb`, `scheme: internet-facing`, `targetType: ip`, `listenPorts: '[{"HTTP":80}]'`, `host: ""` và danh sách các path bị chặn (`blockedPrefixes`).
3. Cập nhật `values.schema.json` để xác thực cú pháp của giao diện cấu hình mới.
4. Thêm template Ingress chuyên dụng dành riêng cho `frontend-proxy` công cộng (`frontend-proxy-public-ingress.yaml`). Template này sẽ định cấu hình hành động chặn (`alb.ingress.kubernetes.io/actions.block-public-path`) thông qua chú thích của ALB Controller.
5. Tạo tệp cấu hình overlay `values-public-alb.yaml` để cho phép bật tính năng này khi triển khai thực tế.

## Acceptance Criteria
- Cấu hình opt-in được thiết lập mặc định tắt, giữ nguyên dịch vụ `frontend-proxy` dưới dạng `ClusterIP:8080`.
- Helm lint chạy thành công không có lỗi trên chart khi dùng file overlay.
- Khi bật overlay public ALB, Helm template render ra Ingress với đầy đủ cấu hình:
  - Cho phép truy cập `/`, `/api/*`, `/images/*`.
  - Từ chối truy cập bằng mã lỗi 403 (fixed-response) đối với các đường dẫn `/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`, `/otlp-http`.
  - Các quy tắc chặn (blocked rules) được render trước quy tắc catch-all `/` để đảm bảo thứ tự khớp mẫu chính xác của ALB.

## Kiểm thử / xác minh
1. Kiểm tra cú pháp của chart:
   ```sh
   helm lint ./techx-corp-chart -f ./techx-corp-chart/values-public-alb.yaml
   ```
2. Render thử cấu hình Ingress public để kiểm tra các annotations và đường dẫn:
   ```sh
   helm template techx-corp ./techx-corp-chart -n techx-tf2 -f ./techx-corp-chart/values-public-alb.yaml -s templates/frontend-proxy-public-ingress.yaml
   ```
3. Đảm bảo cấu hình chặn trả về mã HTTP 403 sử dụng annotation `block-public-path` và cổng đặc biệt `use-annotation`.

## Rủi ro & rollback
- **Rủi ro**: Lỗi render cú pháp annotations làm hỏng quá trình tạo tài nguyên Ingress của AWS ALB Controller. Thứ tự quy tắc khớp path bị đảo lộn dẫn đến việc bỏ lọt truy cập vào các trang admin.
- **Rollback**: Tắt public ALB bằng cách đặt `components.frontend-proxy.publicAlb.enabled = false` và cập nhật lại Helm release để gỡ bỏ Ingress công cộng.

---

## English Summary
This backlog tracks the Helm chart modifications required in the `techx-corp-chart` repository to introduce an opt-in public ALB Ingress interface for the `frontend-proxy`. It implements blocking rules for telemetry and admin paths (`/grafana`, `/jaeger`, `/loadgen`, etc.) returning a fixed-response 403 Access Denied using AWS Load Balancer Controller annotations, while keeping the main service as a ClusterIP and default setup unchanged.
