# Linkerd Service Mesh — GitOps (ArgoCD)

Thư mục này chứa toàn bộ ArgoCD manifests để cài đặt và quản lý **Linkerd** trên cluster production.

## Lý do chọn Linkerd (M16 — gRPC Load Balancing)

gRPC dùng HTTP/2 multiplexing: tất cả request từ một gRPC client đi qua 1 TCP connection duy nhất
tới ClusterIP. kube-proxy forward connection đó vào 1 pod cố định, gây mất cân bằng tải nghiêm trọng
khi service có nhiều replica (checkout → currency, frontend → product-catalog, v.v.).

Linkerd giải quyết vấn đề này bằng cách inject sidecar proxy (`linkerd-proxy`) vào mỗi pod. Proxy
này hiểu gRPC (HTTP/2) và thực hiện **L7 per-request load balancing** tới tất cả pod đích — hoàn
toàn minh bạch với ứng dụng, không cần thay đổi code, áp dụng cho tất cả 18 service cùng lúc.

## Cấu trúc thư mục

```
gitops/linkerd/
├── README.md                           # File này
├── appproject.yaml                     # AppProject "linkerd" riêng với Helm repos được phép
└── applications/
    ├── linkerd-crds.yaml               # App: linkerd-crds chart (sync-wave 0 — CRDs trước)
    └── linkerd-control-plane.yaml      # App: linkerd-control-plane chart (sync-wave 1)
```

Root app-of-apps (`clusters/prod/`) có file `linkerd-application.yaml` trỏ vào thư mục này.

## Sync Order (sync-wave)

```
wave 0: linkerd-crds        → cài CRDs (ServerLink, ServiceProfile, AuthorizationPolicy, ...)
wave 1: linkerd-control-plane → cài control plane (destination, identity, proxy-injector, ...)
(sau đó ArgoCD auto-restart pods có annotation inject trong techx-corp-prod)
```

## Bước chuẩn bị thủ công BẮT BUỘC (một lần duy nhất)

Linkerd yêu cầu bộ mTLS root certificates để thiết lập identity. Certificates phải được tạo
thủ công và lưu vào K8s Secret **trước** khi sync ArgoCD lần đầu.

### 1. Tạo mTLS certificates

```bash
# Cài step CLI (nếu chưa có)
curl -L https://dl.smallstep.com/cli/latest/step_linux_amd64.tar.gz | tar xz
sudo mv step /usr/local/bin/

# Trust anchor (CA, 10 năm — không cần rotate)
step certificate create root.linkerd.cluster.local ca.crt ca.key \
  --profile root-ca --no-password --insecure --not-after=87600h

# Issuer cert (ký bởi CA, 1 năm — Linkerd auto-rotates leaf certs)
step certificate create identity.linkerd.cluster.local issuer.crt issuer.key \
  --profile intermediate-ca --not-after=8760h \
  --ca ca.crt --ca-key ca.key --no-password --insecure
```

### 2. Tạo namespace và K8s Secret

```bash
kubectl create namespace linkerd

# Secret này được linkerd-control-plane chart đọc khi identity.issuer.scheme=kubernetes.io/tls
kubectl create secret generic linkerd-identity-issuer \
  --from-file=tls.crt=issuer.crt \
  --from-file=tls.key=issuer.key \
  -n linkerd
```

### 3. Cập nhật trust anchor trong Application manifest

Paste nội dung `cat ca.crt` vào trường `identityTrustAnchorsPEM` trong file
`applications/linkerd-control-plane.yaml`. CA cert là public, có thể lưu trong Git.

### 4. Trigger ArgoCD sync

Sau khi commit lên `main`, ArgoCD root app-of-apps sẽ phát hiện `linkerd-application.yaml`
trong `clusters/prod/` và tự động tạo + sync các Applications Linkerd theo đúng sync-wave order.

## Inject vào workload namespace

Namespace `techx-corp-prod` được annotate `linkerd.io/inject: enabled` qua Namespace resource
trong `templates/linkerd-namespace-inject.yaml` của main chart. Khi ArgoCD sync main `techx-corp`
Application, tất cả pods mới tạo trong namespace này sẽ tự động được inject `linkerd-proxy` sidecar.

Pods hiện tại cần rolling restart để inject: ArgoCD prune + sync sẽ trigger điều này khi image digest thay đổi.

## Rollback

```bash
# Xóa annotation inject khỏi namespace (pods mới sẽ không inject nữa)
kubectl annotate namespace techx-corp-prod linkerd.io/inject-

# Xóa Linkerd Applications qua ArgoCD (hoặc git revert commit)
# Không xóa CRDs khi còn workloads đang dùng — sẽ gây lỗi
```

## References

- [Linkerd Helm install](https://linkerd.io/docs/tasks/install-helm/)
- [Linkerd GitOps with ArgoCD](https://linkerd.io/2.17/tasks/gitops/)
- [Linkerd gRPC LB](https://linkerd.io/2.17/features/load-balancing/)
- [ADR M16](../docs/adr/ADR-M16-latency-under-load.md)

<!-- Change trail: @chinhgithub04 - 2026-07-24 - M16 Linkerd service mesh via GitOps for gRPC L7 LB. -->
