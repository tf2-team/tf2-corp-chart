# ADR-M10: Secure Delivery với AWS KMS Cosign và Image Admission Fail-Closed

- Trạng thái: IN PROGRESS — supply-chain/admission controls PASS; merge
  enforcement và approval PENDING
- Ngày cập nhật: 2026-07-29
- Go/No-Go liên team: chờ required status check enforcement/negative test, sau
  đó xác nhận từ platform, infra, chart/runtime security và workload owners

## Bối cảnh

Các image ứng dụng do `tf2-corp-platform` build phải có danh tính bất biến và có
thể truy vết từ source đến Pod Production. Chuỗi kiểm chứng gồm:

- Trivy chặn HIGH/CRITICAL trước khi phát hành;
- image được tham chiếu bằng digest;
- AWS KMS signature, CycloneDX SBOM và provenance được lưu trong ECR;
- Sigstore Policy Controller từ chối image nội bộ thiếu chứng thư;
- Pod đang chạy truy được về workflow, commit, PR và reviewer.

Cluster không có Argo CD Development tương đương. Admission được kiểm tra trước
bằng server-side dry-run trong namespace `mandate10-validation`, sau đó xác nhận
trên Production bằng canary cô lập và các request CREATE thật.

## Phạm vi

ADR áp dụng cho image:

- do `tf2-corp-platform` build;
- lưu tại
  `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/**`;
- thuộc production release build set;
- được chart Production triển khai.

Image do nhà cung cấp bên ngoài phát hành, như Linkerd, BusyBox, Envoy, Postgres
và Valkey, không phải artifact do platform ký. Chúng chỉ được admission khi
match explicit allowlist; image không match policy nào tiếp tục bị từ chối.

## Quyết định

### 1. CI security gate

- Không có bypass Trivy riêng theo service.
- Trivy image scan chặn HIGH/CRITICAL trước ECR push.
- Sign, attest và promotion chỉ chạy sau Trivy IaC, Semgrep SAST và TruffleHog
  secret scan bắt buộc.
- Mỗi repo dùng một context ổn định tên `Mandate 10 required gate`; context này
  chỉ PASS khi các test/scan/render thuộc repo đã PASS.
- Context chỉ trở thành merge control sau khi repository admin thêm nó vào
  active default-branch ruleset. Việc này đang chờ hoàn tất tại EV-15.

### 1.1 Dependency pinning và selective delivery

- Third-party GitHub Actions phải pin commit SHA; external Dockerfile `FROM`
  phải pin `@sha256`.
- Release catalog là nguồn chuẩn để phân loại service.
- PR CI và publish chỉ build/scan service có đường dẫn ảnh hưởng thay đổi.
- Unchanged services giữ nguyên digest overlay.
- Production promotion chỉ cập nhật digest của service được rebuild.
- Manual requested/full rebuild phải có lý do; tag release và shared/global
  image paths là các full-build trigger hẹp được chấp thuận.

### 2. Immutable digest và chứng thư

- Chart tham chiếu image ứng dụng theo
  `repository@sha256:<digest>`.
- Pipeline ký release digest bằng AWS KMS.
- Mỗi digest có CycloneDX SBOM và provenance attestation.
- Signature và attestation được lưu tập trung tại
  `techx-prod-corp/cosign-artifacts`.
- Custom provenance predicate dùng URI định danh
  `https://techx-corp.dev/attestations/provenance/v1`. URI này là type
  identifier; payload thực tế nằm trong DSSE attestation ở ECR.

### 3. Admission policy

- Argo application `supply-chain` quản lý Sigstore Policy Controller.
- `ClusterImagePolicy/ecr-signature-policy` chỉ match
  `techx-prod-corp/**`, dùng KMS key
  `f96d445c-43c3-49d3-b508-7243e07c4f27` và yêu cầu:
  - KMS signature;
  - `https://cyclonedx.org/bom`;
  - `https://techx-corp.dev/attestations/provenance/v1`.
- Webhook dùng `failurePolicy: Fail`.
- Admission High Availability (HA): Webhook vận hành với `replicaCount: 3`, `priorityClass: system-cluster-critical`, resource request `250m`/`256Mi` và limit `1`/`512Mi`.
- Node placement & Anti-affinity: Đặt trên `workload-class: critical` nodes (`commonNodeSelector`), bắt buộc phân tách host (`podAntiAffinity` hard cho `kubernetes.io/hostname`) và ưu tiên phân tách Availability Zone (`topology.kubernetes.io/zone`).
- PodDisruptionBudget (PDB): Kích hoạt PDB với `minAvailable: 2` bảo vệ tính sẵn sàng khi bảo trì node.
- GitOps-only recovery: Mọi phục hồi và điều chỉnh cấu hình webhook phải thực hiện qua GitOps commit trên `techx-corp-chart` và Argo CD reconciliation. Không sử dụng `failurePolicy: Ignore` hoặc lệnh `kubectl`/`helm` thao tác trực tiếp trên cluster.
- Namespace chỉ chịu admission policy khi có label
  `policy.sigstore.dev/include=true`.
- `external-image-allowlist-policy` dùng `static: pass` cho các external
  repositories đã kiểm kê; không dùng global `no-match-policy: allow`.
- Production namespace đã opt-in sau khi allowlist được reconcile. Bốn
  server-side dry-run đạt 4/4; signed internal canary CREATE thật chạy thành
  công, còn unsigned internal và unlisted external CREATE thật bị từ chối.
- Label được áp dụng như một operational control, chưa khai báo trong Helm
  template dùng chung.
- Nếu namespace hoặc cluster được tạo lại, operator phải xác nhận hai policy
  `Ready=True`, chạy lại admission tests rồi mới gắn lại opt-in label.

### 4. ECR retention

- Service repository dùng immutable tags, xóa `buildcache` sau một ngày và giữ
  25 ECR records mới nhất.
- `cosign-artifacts` giữ 1000 records mới nhất.
- Một multi-architecture release chiếm nhiều records; 25 records không tương
  đương 25 releases.
- Lifecycle có thể xóa digest vẫn cần cho rollback. Current release chỉ được
  chấp thuận sau khi current/rollback digests được kiểm tra.
- Mọi thay đổi lifecycle phải đi qua repository hạ tầng sở hữu policy.

Nếu runtime digest bị xóa, Pod mới có thể gặp `ErrImagePull` hoặc
`ImagePullBackOff`. Nếu signature/attestation bị xóa nhưng runtime image còn,
admission có thể DENY Pod mới.

## Trạng thái kiểm chứng

| Outcome | Evidence |
|---|---|
| CI security gate | EV-01 |
| KMS signature và attestations `24/24` | EV-04 |
| Immutable Production release | EV-02, EV-05 |
| Admission readiness và fail-closed | EV-08, EV-13 |
| Production admission enforcement: opt-in, dry-run `4/4` và live CREATE | EV-13, EV-14 |
| Webhook HA (3 replicas, critical nodes, PDB minAvailable 2) | EV-15 |
| Runtime traceability | EV-09 |
| Production image inventory và explicit allowlist | EV-11 |
| Current release ECR integrity `24/24` | EV-04, EV-12 |
| Required merge checks | EV-15 — admin pending |
| Action/base-image pinning | EV-15 — PR open |
| Selective build và promotion | EV-15 |

Chi tiết lệnh, raw output và ảnh nằm tại
`docs/evidence/mandate-10/secure-delivery.md`.

## Điều kiện chuyển sang Accepted

1. Merge platform `#128`, chart `#372` và infra `#154` sau review/CI xanh.
2. Repository admin thêm `Mandate 10 required gate` vào active ruleset của cả
   ba default branch với strict branch update.
3. Thu negative evidence độc lập trên cả ba repo: mỗi repo có một PR nhỏ cố
   tình làm required gate đỏ, bị chặn merge, sau đó đóng mà không merge.
4. Merge EV-15 hoàn chỉnh vào `main`.
5. Ghi nhận Go/No-Go của platform, infra, chart/runtime security và workload
   owners liên quan.

## Rollback

Nếu webhook, TLS, KMS hoặc ECR gây gián đoạn admission:

1. Gỡ opt-in label khỏi Production:
   `kubectl label namespace techx-corp-prod policy.sigstore.dev/include-`.
2. Xác nhận Pod admission và workload recovery; label removal không restart các
   Pod đang chạy.
3. Chỉ thay đổi `failurePolicy` bằng một GitOps revert riêng nếu sự cố ảnh hưởng
   namespace khác và đã được owner phê duyệt.
4. Revert workload về digest đã xác minh nếu lỗi thuộc release image.
5. Không tạo allow-all bypass cluster-wide.
6. Lưu incident timeline, Git revision và output kiểm chứng.

## Hệ quả

### Tích cực

- Image ứng dụng có danh tính bất biến và chuỗi truy xuất kiểm chứng được.
- Admission từ chối image nội bộ thiếu signature/SBOM/provenance.
- Webhook HA 3-replica ngăn ngừa nghẽn liveness/readiness probe và Pod restart.
- SBOM và provenance hỗ trợ audit từ Pod về source và pipeline.

### Rủi ro còn lại

- KMS, ECR và Policy Controller trở thành dependency của rollout.
- `failurePolicy: Fail` có thể chặn Pod mới khi webhook gặp sự cố.
- ECR lifecycle có thể làm mất runtime digest hoặc chứng thư rollback.
- External repository mới phải được review và cập nhật allowlist trước rollout.
<!-- Change trail: @hungxqt - 2026-07-29 - Update ADR-M10 with policy-controller webhook HA, critical node placement, PDB, and GitOps-only recovery. -->
