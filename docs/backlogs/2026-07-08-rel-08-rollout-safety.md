# Backlog: REL-08 - Thiết kế rollback và rollout safety chuẩn hơn

## Bối cảnh
Hệ thống TechX Corp hiện tại sử dụng Helm release để triển khai toàn bộ các thành phần dịch vụ. Tuy nhiên, quy trình nâng cấp hiện tại chưa có cơ chế kiểm soát rollout an toàn (rollout safety) chặt chẽ, dẫn đến nguy cơ gián đoạn dịch vụ khi deploy các phiên bản lỗi hoặc không ổn định.

## Vấn đề
- Helm chart hiện tại (`techx-corp-chart`) dựng sẵn template Deployment và hỗ trợ khai báo probe nhưng chưa chuẩn hóa cấu hình cho chiến lược cuộn (`RollingUpdate` strategy), thời gian chờ Pod sẵn sàng (`minReadySeconds`), hay giới hạn thời gian triển khai (`progressDeadlineSeconds`).
- Cơ chế xác thực probe trong `values.schema.json` chỉ hỗ trợ kiểm tra cổng HTTP (`httpGet`) mà chưa hỗ trợ các giao thức khác của Kubernetes như gRPC, TCP, Exec, hoặc loại `startupProbe`.
- Các dịch vụ cơ sở dữ liệu hoặc broker đơn lẻ (`postgresql`, `kafka`, `valkey-cart`) nếu chạy theo cơ chế RollingUpdate mặc định (có surge) sẽ bị xung đột volume mount (do chính sách ReadWriteOnce của PVC), khiến quá trình cập nhật bị treo hoặc gây gián đoạn dữ liệu.

## Giải pháp đề xuất
1. **Thiết lập rollout mặc định**: Bổ sung giao diện cấu hình mặc định vào `values.yaml` và `values.schema.json`:
   ```yaml
   default:
     rollout:
       strategy:
         type: RollingUpdate
         rollingUpdate:
           maxUnavailable: 0
           maxSurge: 1
       minReadySeconds: 10
       progressDeadlineSeconds: 300
   ```
2. **Hỗ trợ ghi đè cấu hình**: Cho phép từng component ghi đè cấu hình thông qua `components.<name>.rollout`. Cài đặt chiến lược non-surge (`maxSurge: 0`, `maxUnavailable: 1`) cho các exception database/broker (`postgresql`, `kafka`, `valkey-cart`) để tránh xung đột dữ liệu/volume, kèm theo tài liệu cảnh báo.
3. **Mở rộng schema của probe**: Cập nhật `values.schema.json` hỗ trợ đầy đủ các loại Kubernetes native probes: `httpGet`, `grpc`, `tcpSocket`, `exec` và thêm tùy chọn `startupProbe` cho container.
4. **Cập nhật readiness probes theo service type**:
   - gRPC (port 8080/3551): `ad`, `cart`, `checkout`, `currency`, `payment`, `product-catalog`, `recommendation`, `product-reviews`.
   - HTTP (port 8080): `frontend`, `frontend-proxy`.
   - TCP (port tương ứng): `shipping`, `email`, `quote`, `flagd`, `kafka`, `postgresql`, `valkey-cart`.

## Acceptance Criteria
- Cú pháp Helm chart qua lệnh `helm lint` không xuất hiện bất kỳ lỗi nào.
- Render template thành công bằng lệnh `helm template` và xác minh:
  - Các component thông thường có đầy đủ cấu hình `strategy.rollingUpdate.maxUnavailable: 0`, `strategy.rollingUpdate.maxSurge: 1`, `minReadySeconds: 10`, và `progressDeadlineSeconds: 300`.
  - Các database/broker (`postgresql`, `kafka`, `valkey-cart`) có cấu hình `maxSurge: 0` và `maxUnavailable: 1`.
  - Toàn bộ 17 services được cấu hình readiness probe chuẩn xác với port và giao thức quy định.
- Chạy thử negative test để xác minh nếu nhập sai key cấu hình probe trong `values.yaml` thì Helm schema validator sẽ báo lỗi chặn lại.

## Kiểm thử / xác minh
1. **Kiểm tra cú pháp tĩnh**:
   ```sh
   helm lint techx-corp-chart
   ```
2. **Kiểm tra template đầu ra**:
   ```sh
   helm template rel08 techx-corp-chart --namespace techx-corp
   ```
3. **Kiểm tra schema validation**: Thêm một trường không tồn tại vào cấu hình probe của bất kỳ component nào trong `values.yaml` và kiểm tra lệnh render có bị fail do schema chặn hay không.

## Rủi ro & rollback
- **Rủi ro**: Một số Pod có thể mất nhiều thời gian hơn để sẵn sàng, dẫn đến việc deploy bị chậm hoặc bị hết thời gian (timeout) do cấu hình `minReadySeconds` hoặc probes quá nhạy.
- **Rollback**: Khôi phục lại các file cấu hình `values.yaml`, `values.schema.json` và `_objects.tpl` về trạng thái ban đầu của commit trước đó, sau đó chạy `helm upgrade` lại để đồng bộ hóa.

---

## English Summary
This backlog item covers the Helm chart implementation details in the `techx-corp-chart` repository for the REL-08 Rollout Safety task. It defines a global default rollout strategy (`RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`, `minReadySeconds: 10`, and `progressDeadlineSeconds: 300`), allows per-component overrides, sets database/broker singletons to non-surge settings, and extends the schema to validate native Kubernetes probes (HTTP, gRPC, TCP, Exec, and Startup probes).
