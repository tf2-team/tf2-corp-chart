# MANDATE-05 - Runtime hardening production evidence

## Thông tin chung

| Thuộc tính               | Giá trị                                                     |
| ------------------------ | ----------------------------------------------------------- |
| Cluster                  | `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod` |
| Repository               | `tf2-team/tf2-corp-chart`                                   |
| Admission implementation | Kubernetes native `ValidatingAdmissionPolicy` (VAP/CEL)     |

## Kết luận

MANDATE-05 đã được triển khai bằng admission native của Kubernetes. Ba nhóm
luật đang chạy `[Deny]` trên toàn cluster và không có `namespaceSelector`:

1. Bắt buộc non-root, cấm UID 0, drop `ALL` capabilities và cấm capability
   không được phê duyệt.
2. Cấm image `latest`, image không tag và digest không hợp lệ.
3. Bắt buộc CPU/memory requests và limits cho container và init container.

Giải pháp hiện tại dùng admission có sẵn trong Kubernetes API server, không dựng
thêm controller hoặc Service cho policy. Policy đang enforce ổn định và không
làm thay đổi storefront, operational routes hoặc flagd.

Sáu workload hệ thống cần quyền network, storage, kernel hoặc cổng thấp được áp
ngoại lệ chính xác theo workload, service account, label, container và
capability. Không namespace nào, bao gồm `kube-system` và `argocd`, được bypass
toàn bộ policy.

## Evidence

### Evidence 01 - Argo CD Synced và Healthy

Kết quả mong đợi: `root-prod`, `runtime-hardening`, `techx-corp` và
`techx-corp-secrets` đều `Synced`/`Healthy`; revision là `4050260...` hoặc một
revision mới hơn đã được kiểm soát.

![Argo CD Synced và Healthy](<mentor-submission/Argo CD Synced.jpg>)

### Evidence 02 - VAP sẵn sàng và binding enforce toàn cluster

Kết quả mong đợi:

- Có đúng ba policy; `GEN` bằng `OBSERVED`; `TYPECHECK` là `<none>`.
- Có đúng ba binding; `ACTIONS` là `[Deny]`.
- Cả ba `NAMESPACE_SELECTOR` là `<none>`.

![VAP enforce toàn cluster](<mentor-submission/VAP-enforce-toàn-cluster.jpg>)

### Evidence 03 - Container chạy root bị từ chối

Kết quả mong đợi: exit code khác 0, đồng thời output chứa:

```text
ValidatingAdmissionPolicy 'runtime-hardening-pod.techx.io'
binding 'runtime-hardening-pod-enforce.techx.io' denied request
Containers must run as non-root
```

![Container chạy root bị từ chối](<mentor-submission/Container-chạy-root-bị-từ-chối.jpg>)

### Evidence 04 - Image latest bị từ chối

Kết quả mong đợi: exit code khác 0, output chứa
`latest and untagged images are forbidden` và tên native VAP/binding.

![Image latest bị từ chối](<mentor-submission/Image-latest-bị-deny.jpg>)

### Evidence 05 - Thiếu resources bị từ chối

Kết quả mong đợi: exit code khác 0, output chứa
`Containers must define CPU and memory requests and limits`.

![Thiếu resources bị từ chối](<mentor-submission/Thiếu-resources-bị-deny.jpg>)

### Evidence 06 - Manifest hợp lệ được chấp nhận

Kết quả mong đợi:

```text
deployment.apps/vap-valid-deployment created (server dry run)
```

Không có object thật được tạo vì sử dụng `--dry-run=server`.

![Manifest hợp lệ được chấp nhận](<mentor-submission/Manifest-hợp-lệ-được-chấp-nhận.jpg>)

### Evidence 07 - argocd không bị exclude

Kết quả mong đợi: exit code khác 0 và output chứa:

```text
ValidatingAdmissionPolicy 'runtime-hardening-pod.techx.io'
with binding 'runtime-hardening-pod-enforce.techx.io' denied request
```

Điều này chứng minh policy áp vào `argocd`. Lệnh không tạo Pod thật.

![argocd không bị exclude](<mentor-submission/argocd-không-bị-exclude.jpg>)

### Evidence 08 - kube-system không bị exclude toàn namespace

Kết quả mong đợi: request bị native VAP từ chối vì thiếu security context và
resources. Chỉ sáu identity chính xác đã ký mới được ngoại lệ; workload khác
trong `kube-system` vẫn bị enforce.

![kube-system không bị exclude toàn namespace](<mentor-submission/kube-system-không-bị-exclude-toàn-namespace.jpg>)

### Evidence 9 - Pod health và flagd

Kết quả mong đợi:

- `UNHEALTHY=0`.
- flagd có `true,true`, restart `0,0`, phase `Running`.

![Pod health và flagd](<mentor-submission/Pod-health.jpg>)

### Evidence 10 - Storefront public, operational routes private

Kết quả mong đợi:

```text
/ 200
/grafana/ 403
/jaeger/ 403
/argocd/ 403
/feature/ 403
```

![Storefront public và operational routes private](<mentor-submission/Storefront-public-operational-routes-private.jpg>)

## SLO evidence đã lưu

Formal SLO evidence nằm tại:

- `12-clusterwide-promotion-gate.md`
- `13-clusterwide-production-acceptance.md`

Kết quả đã ghi nhận:

- 10/10 public product/cart/checkout transaction trả HTTP 200.
- Mười hot-path service có server-span traffic và zero server error.
- p95 của tất cả service dưới 1000 ms; maximum clean-window p95 là 34.94 ms.
- flagd không bị disable hoặc thay đổi.
