# ADR-M10: Secure Delivery với AWS KMS Cosign và Image Admission Fail-Closed

- Trạng thái: Đang nghiệm thu
- Ngày cập nhật: 2026-07-29
- Technical Lead / Security Owner: pending approval
- CDO Reviewer: pending approval
- Rollback Operator: pending assignment

## Bối cảnh

Các image ứng dụng do `tf2-corp-platform` build phải có danh tính bất biến và có
thể truy vết từ source đến Pod Production. Chuỗi kiểm chứng gồm:

- Trivy chặn HIGH/CRITICAL trước khi phát hành;
- image được tham chiếu bằng digest;
- AWS KMS signature, CycloneDX SBOM và provenance được lưu trong ECR;
- Sigstore Policy Controller từ chối image nội bộ thiếu chứng thư;
- Pod đang chạy truy được về workflow, commit, PR và reviewer.

Cluster không có Argo CD Development tương đương. Admission test vì vậy dùng
namespace `mandate10-validation` tách biệt, chỉ chạy server-side dry-run và không
tạo workload thử thật.

## Phạm vi

ADR áp dụng cho image:

- do `tf2-corp-platform` build;
- lưu tại
  `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/**`;
- thuộc production release build set;
- được chart Production triển khai.

Image do nhà cung cấp bên ngoài phát hành, như Linkerd, BusyBox, Envoy, Postgres
và Valkey, không phải artifact do platform ký. Trước khi opt-in namespace
Production, `no-match-policy` phải được cấu hình rõ để các image ngoài glob
không bị từ chối ngoài ý muốn.

## Quyết định

### 1. CI security gate

- Không có bypass Trivy riêng theo service.
- Trivy image scan chặn HIGH/CRITICAL trước ECR push.
- Sign, attest và promotion chỉ chạy sau các security gate bắt buộc.
- Full rebuild là ngoại lệ có lý do; selective build chỉ xử lý service thuộc
  `BUILD_SET`.

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
- Namespace chỉ chịu admission policy khi có label
  `policy.sigstore.dev/include=true`.
- Production namespace chưa được opt-in cho đến khi `no-match-policy`, toàn bộ
  container/initContainer/sidecar và rollback owner được chốt.

### 4. ECR retention

- Service repository dùng immutable tags, xóa `buildcache` sau một ngày và giữ
  25 ECR records mới nhất.
- `cosign-artifacts` giữ 1000 records mới nhất.
- Một multi-architecture release chiếm nhiều records; 25 records không tương
  đương 25 releases.
- Lifecycle có thể xóa digest vẫn cần cho rollback. Retention chỉ được chấp
  thuận sau khi rollback window và current/rollback digests được kiểm tra.
- Mọi thay đổi lifecycle phải đi qua repository hạ tầng sở hữu policy.

Nếu runtime digest bị xóa, Pod mới có thể gặp `ErrImagePull` hoặc
`ImagePullBackOff`. Nếu signature/attestation bị xóa nhưng runtime image còn,
admission có thể DENY Pod mới.

## Trạng thái kiểm chứng

| Kiểm chứng | Kết quả |
|---|---|
| Trivy blocking mode, không còn `shopping-copilot` bypass | PASS |
| 24 current Production digests có `.sig` và `.att` | PASS — 24/24 |
| 24 `.att` manifests có CycloneDX và provenance | PASS — 24/24 |
| Signed internal image ALLOW | PASS |
| Internal digest thiếu artifact DENY | PASS |
| Live webhook `failurePolicy: Fail` | PASS — PR `#359` |
| Retest ALLOW/DENY sau fail-closed | PASS |
| Running Accounting Pod truy về workflow/commit/PR/KMS/SBOM/provenance | PASS |
| Production namespace opt-in | PENDING |
| Explicit `no-match-policy` | PENDING |
| Retention acceptance | PENDING |
| Owner/reviewer/rollback assignment | PENDING |

Chi tiết lệnh, raw output và ảnh nằm tại
`docs/evidence/mandate-10/secure-delivery.md`.

## Điều kiện chuyển sang Accepted

1. Chọn và kiểm chứng `no-match-policy` cho image ngoài phạm vi.
2. Khi opt-in Production, retest:
   - internal signed ALLOW;
   - internal unsigned DENY;
   - external image xử lý đúng theo `no-match-policy`.
3. Chốt rollback window và ECR retention.
4. Ghi nhận Technical Lead/Security Owner, CDO Reviewer và Rollback Operator.
5. Merge toàn bộ evidence sau triển khai vào `main`.

## Rollback

Nếu webhook, TLS, KMS hoặc ECR gây gián đoạn admission:

1. Rollback Operator tạo GitOps revert đưa `failurePolicy: Fail` về `Ignore`.
2. Chờ `supply-chain` Synced/Healthy.
3. Revert workload về digest đã xác minh nếu lỗi thuộc release image.
4. Không tắt policy cluster-wide hoặc tạo allow-all bypass lâu dài.
5. Lưu incident timeline, Git revision và output kiểm chứng.

## Hệ quả

### Tích cực

- Image ứng dụng có danh tính bất biến và chuỗi truy xuất kiểm chứng được.
- Admission từ chối image nội bộ thiếu signature/SBOM/provenance.
- SBOM và provenance hỗ trợ audit từ Pod về source và pipeline.

### Rủi ro còn lại

- KMS, ECR và Policy Controller trở thành dependency của rollout.
- `failurePolicy: Fail` có thể chặn Pod mới khi webhook gặp sự cố.
- ECR lifecycle có thể làm mất runtime digest hoặc chứng thư rollback.
- Image bên ngoài phạm vi cần policy riêng hoặc explicit no-match behavior.
