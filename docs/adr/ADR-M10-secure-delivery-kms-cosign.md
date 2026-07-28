# ADR-M10: Secure Delivery với AWS KMS Cosign và Image Admission Fail-Closed

- Trạng thái: Đề xuất
- Ngày: 2026-07-28
- Technical Lead / Security Owner: pending approval
- CDO Reviewer: pending approval
- Rollback Operator: pending assignment

## Bối cảnh

Hệ thống cần bảo đảm các image ứng dụng do đội ngũ tự xây dựng có thể được xác
minh từ lúc build đến lúc được Kubernetes admission. Các rủi ro chính gồm:

1. Policy Controller hoặc webhook TLS gặp lỗi có thể làm gián đoạn rollout nếu
   bật Fail-Closed quá sớm.
2. Pipeline từng có ngoại lệ Trivy cho `shopping-copilot`, làm một service không
   tuân theo cùng security gate như các release services còn lại.
3. Image dùng tag có thể trỏ tới nội dung khác theo thời gian và làm mất liên kết
   chính xác giữa chart, CI run và artifact đã ký.
4. Signature, SBOM và provenance được lưu trong ECR cần có retention phù hợp với
   release digest; nếu artifact bị xóa, lần admission/recreate Pod sau đó có thể
   bị từ chối.
5. Production namespace có thể chứa container sử dụng image do nhà cung cấp bên
   ngoài phát hành, không thuộc quyền build/sign của platform. Opt-in namespace
   mà chưa xác định `no-match-policy` có thể vô tình chặn các container này.
6. Không có Argo CD Development tương đương để kiểm thử toàn bộ admission flow;
   việc kiểm thử phải dùng namespace validation tách biệt trên cluster hiện có.

## Phạm vi quyết định

Quyết định này áp dụng cho image ứng dụng do đội ngũ tự xây dựng:

- do `tf2-corp-platform` build;
- được lưu tại
  `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/**`;
- được release pipeline chọn trong production build set;
- được triển khai bởi chart production.

Các image do nhà cung cấp bên ngoài phát hành, như BusyBox, Envoy, Postgres và
Valkey, nằm ngoài yêu cầu digest, KMS signature, SBOM và provenance của ADR này.
Việc cho phép chúng trong một namespace opt-in phải được xử lý rõ bằng
policy/no-match behavior, thay vì tuyên bố chúng đã được platform ký.

Required Status Checks của GitHub Branch Protection không nằm trong phạm vi
quyết định hiện tại. CI vẫn phải fail khi Trivy phát hiện HIGH/CRITICAL, nhưng ADR
không khẳng định GitHub luôn chặn merge một PR đỏ.

## Quyết định

### 1. Chuẩn hóa Sigstore Policy Controller

- Triển khai upstream Sigstore Policy Controller Helm chart được pin version qua
  Argo CD application độc lập `supply-chain`.
- Dùng IRSA để controller truy cập KMS/ECR theo quyền tối thiểu.
- Dùng `ClusterImagePolicy` chỉ match phạm vi image ứng dụng do đội ngũ tự xây
  dựng trong Production ECR.
- Bắt đầu với `failurePolicy: Ignore` trong giai đoạn kiểm tra controller,
  TLS/CA, IRSA, KMS, artifact coverage và policy behavior.
- Chỉ opt-in namespace bằng label
  `policy.sigstore.dev/include=true` sau khi đã kiểm kê toàn bộ containers trong
  namespace.

`failurePolicy: Ignore` chỉ quy định hành vi khi webhook không thể xử lý request;
nó không vô hiệu hóa quyết định DENY khi webhook hoạt động bình thường.

### 2. Immutable digest và chứng thư tập trung

- Release pipeline resolve immutable digest cho mỗi image ứng dụng do đội ngũ tự
  xây dựng.
- Chart production tham chiếu image theo dạng
  `repository@sha256:<digest>`.
- Ký mỗi release digest bằng AWS KMS.
- Tạo CycloneDX SBOM và provenance attestation cho mỗi release digest.
- Lưu OCI signature/attestation trong
  `techx-prod-corp/cosign-artifacts` thông qua `COSIGN_REPOSITORY`.
- Xác minh KMS bằng URI dạng
  `awskms:///arn:aws:kms:us-east-1:493499579600:key/<key-id>`.

Không mở rộng `ClusterImagePolicy` sang external registries trong Mandate 10.

### 3. CI security gate thống nhất

- Gỡ bỏ bypass Trivy riêng của `shopping-copilot`.
- Các service trong production build set dùng Trivy blocking mode cho
  HIGH/CRITICAL.
- Production workflow chỉ tiếp tục push/sign/attest khi các bước bắt buộc thành
  công.
- Việc vá dependency phải được review như thay đổi ứng dụng riêng, không được
  coi là thay đổi admission policy.

Production run `30370423129` là evidence pipeline cho tập 24 release artifacts.
Số workload thực sự active trên Production phải được xác nhận độc lập từ Argo
rendered manifests và running Pods. Việc build AIOps không tự động chứng minh
AIOps đang được deploy.

### 4. ECR lifecycle và retention

Lifecycle của service repository và `cosign-artifacts` được đánh giá riêng:

- Production service repositories dùng immutable tags và hai lifecycle rules:
  expire `buildcache` sau một ngày, sau đó giữ 25 ECR records mới nhất bằng
  `tagStatus: any`.
- Repository tập trung `techx-prod-corp/cosign-artifacts` dùng cùng cấu trúc hai
  rules nhưng override ngưỡng giữ thành 1000 records; AWS verification ngày
  2026-07-29 ghi nhận 249 records, chưa chạm ngưỡng.
- Không mô tả module hiện tại là lifecycle ba rule.
- Một multi-architecture release chiếm nhiều ECR records, do đó giữ 25 records
  không đồng nghĩa giữ 25 releases.
- Production workflow có thể để lại image records khi một service đã push thành
  công nhưng toàn workflow thất bại ở bước sau. Các records không được promote
  vẫn tiêu thụ cùng retention quota với digest đang chạy.
- Quan sát ngày 2026-07-29 cho thấy `frontend` và `accounting` đều có 20 records,
  mỗi build set chiếm khoảng 5 records. Ngưỡng 25 chỉ còn headroom khoảng một
  build trước khi đầy; build kế tiếp có thể expire nhóm 5 records cũ nhất.
- Thời gian giữ signature, SBOM và provenance phải không ngắn hơn thời gian một
  release digest còn có thể được deploy hoặc rollback.
- Lifecycle policy không biết digest nào còn được GitOps tham chiếu. Trước mọi
  thay đổi retention phải chạy lifecycle preview và bảo vệ current/rollback
  digests.
- Thay đổi lifecycle phải được thực hiện trong repository hạ tầng sở hữu policy,
  không sửa nóng trên AWS Console rồi bỏ ngoài GitOps/IaC.

Phân biệt hai lỗi:

- Runtime image digest bị lifecycle xóa: Pod đang chạy không dừng ngay, nhưng
  Pod mới trên node cần pull image có thể chuyển từ `ErrImagePull` sang
  `ImagePullBackOff`.
- Signature/attestation bị xóa trong khi runtime image còn: sau khi namespace
  opt-in, admission policy có thể từ chối tạo Pod; đây không phải
  `ImagePullBackOff`.

Retention chỉ được chấp nhận khi rollback window chính thức không dài hơn số
release thực tế còn giữ, và current/rollback digests cùng chứng thư tương ứng đã
được kiểm tra còn tồn tại. Tăng từ 5 lên 25 records là cải thiện cần thiết nhưng
chỉ được xem là chấp nhận có điều kiện; thiết kế mục tiêu phải tách candidate
builds khỏi promoted Production images hoặc bảo vệ rõ các promoted/rollback
digests bằng lifecycle đã preview.

### 5. Lộ trình admission enforcement

Thực hiện theo thứ tự:

1. Xác nhận `supply-chain` Synced/Healthy, controller và policy Ready.
2. Kiểm kê từng release digest của image ứng dụng trong phạm vi, bảo đảm có KMS
   signature, CycloneDX SBOM và provenance.
3. Xác nhận production digest PR đã merge và workloads ổn định.
4. Tạo namespace `mandate10-validation`, chỉ opt-in namespace này.
5. Khi vẫn giữ `failurePolicy: Ignore`, kiểm tra:
   - signed internal image trả về ALLOW;
   - confirmed-unsigned internal image trả về DENY.
6. Xác định và kiểm chứng `no-match-policy` cho image do nhà cung cấp bên ngoài
   phát hành.
7. Chỉ sau khi các bước trên đạt, tạo GitOps PR đổi `failurePolicy: Ignore` thành
   `Fail`.
8. Chờ Argo Synced/Healthy và chạy lại positive/negative admission tests.
9. Chỉ cân nhắc opt-in Production namespace sau khi kiểm kê mọi container,
   initContainer và sidecar trong namespace.

Không dùng image chưa ký do nhà cung cấp bên ngoài phát hành làm negative test
cho signature policy, vì kết quả đó chủ yếu phản ánh no-match behavior. Negative
test phải dùng một digest thuộc `techx-prod-corp/**` và được xác nhận không có
chứng thư hợp lệ.

## An toàn rollout

Do không có Argo CD Development, quy tắc Dev-First được thay bằng kiểm thử có cô
lập:

- production webhook vẫn giữ safe mode `Ignore`;
- test dùng namespace validation riêng;
- chỉ dùng `--dry-run=server`, không tạo workload thử thật;
- không label namespace Production trong giai đoạn đầu;
- mọi thay đổi `failurePolicy` phải qua GitOps PR;
- phải có named operator, rollback owner và maintenance window phù hợp.

Không thực hiện admission test trong lúc Argo/workload đang biến động bởi mandate
khác, vì kết quả rollout và traceability khi đó không đủ tin cậy.

## Tiêu chí kiểm chứng

ADR chỉ đủ điều kiện chuyển sang `Accepted` khi có bằng chứng:

1. Production workflow pass cho toàn bộ production build set ở Trivy blocking
   mode.
2. Mỗi release digest trong scope verify thành công:
   - AWS KMS signature;
   - CycloneDX SBOM;
   - provenance attestation.
3. Chart/Argo rendered manifests dùng đúng digest đã merge của các image ứng
   dụng trong phạm vi.
4. Policy Controller, TLS/CA, IRSA và KMS hoạt động ổn định.
5. Signed internal image ALLOW và unsigned internal image DENY bằng
   server-side dry-run trong validation namespace.
6. `failurePolicy: Fail` được reconcile thành công và hai admission tests vẫn
   đạt.
7. Một running Pod được truy vết đầy đủ về digest, workflow, commit, PR/reviewer,
   signature, SBOM và provenance.
8. Technical Lead/Security Owner, CDO Reviewer và Rollback Operator được ghi
   nhận.

## Rollback

Nếu webhook gặp sự cố TLS, network, KMS/ECR hoặc gây gián đoạn admission:

1. Named operator tạo hoặc áp dụng GitOps revert đưa
   `failurePolicy: Fail` về `Ignore`.
2. Chờ `supply-chain` application Synced/Healthy và xác nhận admission phục hồi.
3. Nếu lỗi do release digest, revert chart về digest đã được xác minh trước đó.
4. Không cấp bypass rộng, không tắt toàn bộ policy và không sửa nóng ngoài GitOps
   như một giải pháp lâu dài.
5. Lưu incident timeline, revision rollback và output kiểm chứng vào evidence.

## Hệ quả

### Tích cực

- Image ứng dụng do đội ngũ tự xây dựng có danh tính bất biến bằng digest.
- Có thể xác minh tính toàn vẹn và nguồn phát hành bằng AWS KMS signature.
- SBOM và provenance hỗ trợ audit và truy vết từ workload về quá trình build.
- Admission policy giảm đáng kể nguy cơ triển khai image nội bộ không được ký
  hoặc thiếu chứng thư bắt buộc.

### Đánh đổi và rủi ro còn lại

- KMS, ECR, policy controller và lifecycle trở thành các dependency quan trọng
  của quá trình rollout.
- `failurePolicy: Fail` có thể chặn Pod mới nếu webhook hoặc dependency gặp lỗi.
- Trivy/signature không chứng minh phần mềm hoàn toàn không có lỗ hổng.
- Image do nhà cung cấp bên ngoài phát hành vẫn cần quản trị rủi ro riêng.
- Chữ ký mật mã cung cấp bằng chứng integrity/authenticity kỹ thuật; ADR không
  tuyên bố đây là chữ ký điện tử có giá trị pháp lý.
