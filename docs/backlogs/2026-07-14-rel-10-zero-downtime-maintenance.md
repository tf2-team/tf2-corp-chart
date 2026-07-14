# Backlog: REL-10 - Bảo trì không làm rớt luồng ra tiền

## Liên kết yêu cầu

- Directive #3: Bảo trì trong giờ vận hành - luồng ra tiền không được rớt.
- Hạn nộp: 16/07/2026.
- Trụ chính: Reliability.
- Trụ liên quan: Performance Efficiency, Auditability, Security.

## Mục tiêu

Khi drain một node stateless hoặc rolling restart, luồng công khai
`browse -> cart -> checkout` tiếp tục đáp ứng:

- Checkout success rate >= 99%.
- Browse/cart success rate >= 99.5%.
- Storefront p95 < 1 giây.
- Pod chưa Ready không nhận traffic.
- Không bypass flagd hoặc làm public các cổng vận hành.

## Thay đổi trong backlog

- Nâng production floor lên hai replica cho các Deployment stateless tham gia
  trực tiếp hoặc đồng bộ vào luồng mua hàng.
- Render PDB `minAvailable: 1` cho cả Deployment cố định và HPA có floor >= 2.
- Giữ readiness probe và rolling update `maxUnavailable: 0`.
- Bổ sung soft spread theo zone/hostname cho `frontend-proxy` và `flagd` mà
  không phá hard placement hiện tại.
- Bổ sung Grafana dashboard `Directive #3 - Maintenance SLO` dùng telemetry
  thật của frontend, kube-state-metrics và EndpointSlice.
- Bổ sung k6 test từ public storefront với threshold đúng directive.
- Bổ sung runbook pre-flight, drain, abort, recovery và audit evidence.

## Tiêu chí chấp nhận kỹ thuật

- [x] `helm lint` thành công với production overlays.
- [x] `helm template` tạo HPA `minReplicas: 2` và PDB cho workload stateless.
- [x] Không tạo PDB/replica giả cho StatefulSet singleton.
- [x] Dashboard JSON hợp lệ và được Grafana provisioning load.
- [x] `k6 inspect` xác nhận test browse/cart/checkout và đủ bốn threshold.
- [ ] Argo CD sau merge là `Synced` và `Healthy` đúng Git revision.
- [ ] Tất cả replica production Ready trước maintenance.
- [ ] Mentor chứng kiến drain/rolling restart; k6 exit `0`; dashboard không vi
  phạm SLO.
- [ ] Ghi đủ evidence theo runbook.

## Release gate và residual risk

Kafka và `valkey-cart` hiện là stateful singleton. Tăng `replicas: 2` đơn thuần
không tạo replication hoặc failover an toàn, nên thay đổi này không giả vờ giải
quyết chúng. Node dùng cho buổi nghiệm thu đầu tiên phải là node stateless và
không được chứa các workload trên.

Để tuyên bố toàn bộ hệ thống không còn single point of failure, TF phải có một
change riêng cho stateful HA gồm kiến trúc quorum/replication, storage, migration,
backup/restore, failover test, chi phí và rollback. Cho đến lúc đó đây là residual
risk có chủ sở hữu, không phải tiêu chí đã hoàn thành.

## Kế hoạch nghiệm thu

Thực hiện đúng
[`docs/operations/directive-03-maintenance.md`](../operations/directive-03-maintenance.md),
hẹn mentor và lưu evidence vào task/PR. Không tự drain production trước khi có
khung giờ, baseline xanh và người quan sát SLO độc lập.
