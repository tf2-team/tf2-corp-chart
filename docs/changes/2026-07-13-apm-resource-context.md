# Change: Bổ sung resource context cho APM Dashboard

## Bối cảnh

APM Dashboard sử dụng các resource attribute `deployment.environment.name`,
`service.namespace` và `service.name` để lọc metrics, logs và traces. Telemetry
production đã có dữ liệu nhưng thiếu hai attribute đầu, khiến Grafana hiển thị
`<<not defined>>` cho Environment và Namespace, đồng thời không liệt kê service.

## Thay đổi

Processor `resource` của OpenTelemetry Collector bổ sung:

- `deployment.environment.name=production`
- `service.namespace=techx-corp-prod`

Processor này đã được sử dụng trong cả ba pipeline metrics, logs và traces.
Prometheus cũng đã bật `promote_resource_attributes` cho hai attribute trên nên
chúng sẽ được chuyển thành label phục vụ truy vấn Grafana.

## Kiểm thử trước triển khai

- `helm dependency build .`
- `helm lint .`
- `helm template techx . > /tmp/apm-resource-context.yaml`
- Xác nhận manifest render chứa hai resource attribute mới.
- `git diff --check`

## Xác minh sau triển khai

1. Xác nhận Argo CD ở trạng thái `Synced/Healthy`.
2. Xác nhận DaemonSet `otel-collector-agent` rollout thành công.
3. Tạo traffic mới qua storefront và chờ telemetry được thu thập.
4. Xác nhận APM Dashboard hiển thị:
   - Environment: `production`
   - Namespace: `techx-corp-prod`
   - Name: danh sách service production
5. Xác nhận RED metrics, Jaeger traces và OpenSearch logs lọc được theo service.

Telemetry cũ không được bổ sung attribute ngược thời gian; bằng chứng cần sử
dụng dữ liệu phát sinh sau thời điểm rollout.

## Rủi ro và rollback

Thay đổi làm tăng hai label có cardinality cố định, vì vậy tác động cardinality
thấp. Nếu Collector không khởi động hoặc pipeline lỗi, rollback bằng cách revert
commit này và để Argo CD đồng bộ lại revision trước đó.
