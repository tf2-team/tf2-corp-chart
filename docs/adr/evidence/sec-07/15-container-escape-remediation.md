# SEC-07 - Container escape admission gap remediation

## Tóm tắt

Ngày 20/07/2026, kiểm thử đối kháng trên production phát hiện hai Pod có cấu hình nguy hiểm vẫn được admission chấp nhận trong namespace `techx-corp-prod`:

| Pod | Cấu hình vượt qua policy cũ | Kết quả kiểm chứng |
|---|---|---|
| `poc-privileged` | `privileged: true` kết hợp `runAsNonRoot: true`, UID 1000 và `drop: [ALL]` | Container nhìn thấy thiết bị thật của worker node, gồm các block device |
| `poc-hostesc` | `hostNetwork: true`, `hostPID: true` và `hostPath: /` | Container đọc được filesystem của worker node và truy cập được AWS identity của node |

Mức độ: **Critical**. Đây là khoảng trống trong phạm vi validation, không phải do namespace bị loại khỏi enforcement. Binding vẫn dùng `Deny` trên toàn cluster.

## Lỗi là gì

Policy cũ xác nhận container chạy non-root, không dùng UID 0, drop capability, dùng image cố định và có request/limit. Tuy nhiên, policy chưa từ chối các cơ chế có thể phá vỡ ranh giới container:

- `securityContext.privileged: true`;
- `allowPrivilegeEscalation` không được đặt thành `false`;
- dùng PID, IPC hoặc network namespace của host;
- mount filesystem của node bằng `hostPath`.

Vì vậy manifest có thể thỏa toàn bộ biểu thức cũ nhưng vẫn đạt quyền tương đương root trên worker node.

## Nguyên nhân

1. Validation ban đầu bám theo các trường trực tiếp của Mandate 5 nhưng chưa mô hình hóa đường container escape.
2. `privileged: true` làm mất ý nghĩa bảo vệ thực tế của `drop: [ALL]`.
3. `runAsNonRoot` chỉ kiểm UID trong container; nó không ngăn việc đọc host filesystem hoặc dùng host network.
4. Scanner inventory dùng cùng phạm vi kiểm tra cũ nên không phát hiện `privileged`, host namespace và `hostPath`.
5. Pod-level exception hệ thống chưa yêu cầu controller owner, tạo khả năng Pod tự tạo giả profile hệ thống.

## Tác động

- Đọc hoặc sửa dữ liệu trên worker node, gồm dữ liệu kubelet và dữ liệu của Pod cùng node.
- Truy cập Instance Metadata Service qua host network và nhận temporary credential của node IAM role.
- Truy cập raw block device, kernel interface và có khả năng thoát container.
- Từ một Pod có thể mở rộng thành chiếm node, di chuyển ngang trong cluster hoặc truy cập tài nguyên AWS bằng quyền node.
- Scanner cũ có thể báo không có drift dù Pod nguy hiểm đang chạy.

Không ghi credential, token hoặc nội dung secret vào evidence này.

## Cách khắc phục

Admission policy được bổ sung cho Pod, Deployment, StatefulSet, DaemonSet, ReplicaSet, ReplicationController, Job và CronJob:

- workload thường phải đặt `allowPrivilegeEscalation: false`;
- cấm `privileged: true`;
- cấm `hostNetwork`, `hostPID` và `hostIPC`;
- cấm volume `hostPath`;
- tiếp tục bắt buộc non-root, UID khác 0, drop `ALL`, không re-add capability, image cố định và request/limit;
- chỉ cho phép host access đối với profile hệ thống đã ký duyệt;
- Pod thuộc exception hệ thống phải có controller owner phù hợp, giảm khả năng tạo Pod lookalike trực tiếp.

Scanner inventory được bổ sung các Rule ID:

| Rule ID | Ý nghĩa |
|---|---|
| `PRIVILEGED` | Container chạy privileged |
| `PRIV_ESC` | Không đặt `allowPrivilegeEscalation: false` |
| `HOST_NETWORK` | Pod dùng network namespace của host |
| `HOST_PID` | Pod dùng PID namespace của host |
| `HOST_IPC` | Pod dùng IPC namespace của host |
| `HOST_PATH` | Pod mount hostPath |

## Kiểm thử

Chạy toàn bộ admission suite trên cluster test cục bộ:

```powershell
$env:PATH = "$env:USERPROFILE\go\bin;$env:PATH"
pwsh -NoProfile -File .\scripts\verify-runtime-hardening.ps1 -KubeContext mandate5-test
```

Kết quả đạt:

```text
PASS all VAP policies observed with zero type-check warnings
PASS denied: invalid-privileged-pod.yaml
PASS denied: invalid-host-access-deployment.yaml
PASS denied: invalid-hostpath-cronjob.yaml
PASS native CREATE and UPDATE admission tests
PASS production workload render: zero VAP denials
```

Kiểm tra exception hệ thống:

```powershell
$prod = 'arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod'
pwsh -NoProfile -File .\scripts\verify-system-exceptions.ps1 `
  -SourceKubeContext $prod `
  -TestKubeContext mandate5-test
```

Kết quả đạt:

```text
PASS admitted: DaemonSet/aws-node exact profile
PASS admitted: DaemonSet/kube-proxy exact profile
PASS admitted: DaemonSet/ebs-csi-node exact profile
PASS admitted: Deployment/ebs-csi-controller exact profile
PASS admitted: Deployment/coredns exact profile
PASS denied: Pod/coredns ownerless lookalike
PASS exact system exception and near-miss admission suite
```

## Trình tự triển khai production

1. Merge thay đổi và để Argo CD đồng bộ policy.
2. Xác nhận ba policy không có type-check warning và ba binding vẫn là `Deny`, không có namespace exclusion.
3. Chạy server dry-run với ba fixture exploit; tất cả phải bị `ValidatingAdmissionPolicy` từ chối.
4. Xóa hai Pod POC sau khi lưu evidence cần thiết.
5. Chạy scanner mới và xác nhận không còn `poc-privileged` hoặc `poc-hostesc`.
6. Kiểm tra toàn bộ Pod healthy, storefront vẫn public, operational routes vẫn private và `flagd` không bị thay đổi.

## Trạng thái

- Bản vá và regression test: hoàn tất trong Git.
- Local admission verification: pass.
- Containment production: hai Pod `poc-hostesc` và `poc-privileged` đã bị xóa ngày 20/07/2026; `flagd` vẫn Ready sau thao tác.
- Phòng tái diễn trên production: chỉ được coi là hoàn tất sau khi merge, Argo CD sync thành công và server dry-run xác nhận các fixture exploit bị deny.
