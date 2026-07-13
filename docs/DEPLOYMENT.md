# Tài liệu Hướng dẫn Triển khai End-to-End (Production Runbook)

> [!NOTE]
> **Vai trò của Repository này (chart):**
> Repository này chịu trách nhiệm quản lý **Helm chart**, cấu hình **public ALB Ingress** (`values-public-alb.yaml`), **smoke test**, **GitOps (Argo CD)**, và quy trình **upgrade/rollback** an toàn.  
> Chart consume image theo quy ước **`[REGISTRY]/[PROJECT]/[SERVICE]:[VERSION]`**.
>
> **Tên repo GitHub vs thư mục local:** remote GitHub là  
> [`https://github.com/tf2-team/tf2-corp-chart`](https://github.com/tf2-team/tf2-corp-chart)  
> (branch dev: `techx-dev-corp`). Thư mục monorepo local có thể vẫn tên `techx-corp-chart` — **Argo CD `repoURL` / `sourceRepos` phải dùng `tf2-corp-chart`**, không dùng tên folder.

---

## 1. Mục tiêu (Objectives)

- Deploy ứng dụng TechX Corp lên EKS (ưu tiên **GitOps / Argo CD**; Helm break-glass khi khẩn cấp).
- Gắn đúng image từ ECR nested (`techx-corp/<service>` hoặc `techx-dev-corp/<service>`).
- Bật public ALB cho storefront, chặn route nhạy cảm.
- Xác minh bằng smoke test; rollback khi cần (`git revert` → Argo sync là chuẩn).

## 2. Bản đồ Repository

| Repository | Vai trò |
|---|---|
| **`techx-corp-platform`** | Build/push images (CI/CD hoặc bake) |
| **`techx-corp-infra`** | VPC, EKS, nested ECR, IAM (GHA OIDC, ALB Controller, ESO IRSA, ASM shells), optional Argo CD install |
| **`tf2-corp-chart`** (GitHub) / local `techx-corp-chart` | Helm chart, secrets-chart (ESO), ALB values, smoke test, rollout safety, `gitops/clusters/*` |

## 3. Điều kiện tiên quyết

- Cluster EKS sẵn sàng, `kubectl` context đúng:
  - **Prod:** `techx-tf2`
  - **Dev:** `techx-dev` (hoặc tên cluster dev hiện tại)
- AWS Load Balancer Controller đã cài trong `kube-system`.
- **SEC-05:** ESO installed, `ClusterSecretStore` Ready, ASM values bootstrapped, **`techx-corp-secrets`** ExternalSecrets Ready (or use `-f values-demo.yaml` for local demo only).
- Images đã có trên ECR theo format nested (xem Phase 3 / platform repo).
- **Helm** v3+, **kubectl**, **bash** (smoke test); **argocd** CLI optional (có thể dùng UI / `kubectl`).
- **GitOps:** Argo CD installed (`argocd` namespace); repo credential trong `argocd` nếu repo private (GitHub App / deploy key / PAT).
- **Metrics Server:** chart cài kèm subchart `metrics-server` (default `enabled: true`) để HPA đọc CPU/memory. **Không** cần cài sẵn trong `kube-system`. Nếu cluster **đã** có Metrics Server (một APIService `v1beta1.metrics.k8s.io` duy nhất), tắt trong overlay: `metrics-server.enabled: false`.
- **Prometheus Adapter:** chart cài kèm subchart `prometheus-adapter` (default `enabled: true`) để HPA đọc RPS External metrics từ Prometheus. Tắt: `prometheus-adapter.enabled: false` (chỉ còn CPU/memory HPA).

## 4. Hằng số & quy ước image

### Production

| Hằng số | Giá trị |
|---|---|
| Account / Region | `493499579600` / `us-east-1` |
| EKS | `techx-tf2` |
| Namespace | `techx-corp-prod` |
| Helm / Argo release name | `techx-corp` |
| Argo CD Application | `techx-corp` (`gitops/clusters/prod/`) |
| Argo CD AppProject | `techx-corp` |
| Git `repoURL` | `https://github.com/tf2-team/tf2-corp-chart.git` |
| Git `targetRevision` | `main` |
| Value files | `values.yaml` + `values-public-alb.yaml` + `values-prod.yaml` |
| `default.image.repository` | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp` |
| `default.image.tag` | VERSION only, ví dụ `sha-a1b2c3d` hoặc `v1.2.3` |

### Development

| Hằng số | Giá trị |
|---|---|
| EKS | `techx-dev` (dev cluster) |
| Namespace | `techx-corp-dev` |
| Helm / Argo release name | `techx-corp-dev` |
| Argo CD Application | `techx-corp-dev` (`gitops/clusters/dev/`) |
| Argo CD AppProject | `techx-corp-dev` |
| Git `repoURL` | `https://github.com/tf2-team/tf2-corp-chart.git` |
| Git `targetRevision` | `techx-dev-corp` |
| Value files | `values.yaml` + `values-public-alb.yaml` + `values-dev.yaml` |
| `default.image.repository` | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-dev-corp` |
| `default.image.tag` | VERSION đã push từ branch `techx-dev-corp` |

### Quy ước image (chart template)

```text
[REGISTRY]/[PROJECT]/[SERVICE]:[VERSION]
```

Template (`templates/_objects.tpl`) render:

```text
{{ default.image.repository }}/{{ component.name }}:{{ default.image.tag }}
```

Ví dụ:

```text
493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp/ad:sha-a1b2c3d
493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp/frontend:sha-a1b2c3d
493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp/checkout:sha-a1b2c3d
```

| Helm value | Ý nghĩa |
|---|---|
| `default.image.repository` | **REGISTRY/PROJECT** — không kèm service |
| `default.image.tag` | **VERSION** — không còn suffix `-service` |

> **Deprecated:** `repository:tag` dạng `.../techx-corp:1.0-ad` (service trong tag).

Component có `imageOverride.repository` (postgres, flagd, …) dùng full `repository:tag` public image, không append service path.

OpenSearch is a **first-party chart component** (`components.opensearch`) using the custom platform image  
`{{ default.image.repository }}/opensearch:{{ default.image.tag }}`  
(build: `src/opensearch/Dockerfile`). Promote by updating **only** `default.image.tag` (and repository per env).

---

## Phase 1–2: Hạ tầng & ALB Controller (tham chiếu)

*Chi tiết đầy đủ: repo `techx-corp-infra` / `techx-corp-platform` docs/DEPLOYMENT.md.*

Tóm tắt:

1. Terraform bootstrap + `environments/production` (EKS, nested ECR `techx-corp/*`, GHA role).
2. `aws eks update-kubeconfig --region us-east-1 --name techx-tf2`
3. Cài AWS Load Balancer Controller từ Terraform output `aws_load_balancer_controller_helm_command`.

   Output includes **`region`**, **`vpcId`**, and IRSA `role-arn`. Required so the controller does not rely on EC2 IMDS (pods often cannot reach metadata → CrashLoop with `failed to get VPC ID` / `ec2imds … deadline exceeded`).

   ```bash
   helm repo add eks https://aws.github.io/eks-charts && helm repo update
   terraform -chdir=../techx-corp-infra/environments/production \
     output -raw aws_load_balancer_controller_helm_command
   # Run the printed helm upgrade --install
   kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=120s
   ```

Nested ECR (Terraform module `ecr`) phải tồn tại **trước** khi pod pull image, ví dụ: `techx-corp/ad`, `techx-corp/checkout`, …

4. **SEC-05 secrets path** (before app chart with default `values.yaml`):

   Bootstrap ASM values from `techx-corp-infra` (current live credentials only). Use full extension:

   ```powershell
   # Windows PowerShell (recommended)
   .\scripts\bootstrap-asm-secrets.ps1 techx-corp/production us-east-1
   ```

   ```cmd
   REM Windows CMD
   scripts\bootstrap-asm-secrets.cmd techx-corp/production us-east-1
   ```

   ```bash
   # Bash / Git Bash / WSL
   ./scripts/bootstrap-asm-secrets.sh techx-corp/production us-east-1
   ```

   Install ESO (infra) and wait until Helm `STATUS: deployed` — do not interrupt `--wait`.  
   If you see `another operation is in progress`, uninstall then reinstall (infra DEPLOYMENT troubleshooting §5).

   ```bash
   # From techx-corp-infra
   terraform -chdir=environments/production output -raw external_secrets_helm_command
   # run printed command; then:
   helm status external-secrets -n external-secrets   # expect deployed

   terraform -chdir=environments/production output -raw external_secrets_cluster_secret_store_manifest | kubectl apply -f -
   kubectl get clustersecretstore aws-secretsmanager
   ```

   Then ExternalSecrets release (after ESO + ClusterSecretStore Ready; cwd = chart root):

   ```bash
   # Prod
   helm upgrade --install techx-corp-secrets ./secrets-chart \
     -n techx-corp-prod --create-namespace \
     -f secrets-chart/values.yaml \
     -f secrets-chart/values-prod.yaml
   kubectl -n techx-corp-prod wait --for=condition=Ready externalsecret --all --timeout=120s

   # Dev: -n techx-corp-dev -f secrets-chart/values-dev.yaml
   ```

   Runbook: [operations/external-secrets.md](./operations/external-secrets.md).

   Local demo **without** ESO: add `-f values-demo.yaml` to the app chart (plaintext demo only).

---

## Phase 3: Images (tham chiếu platform)

Images được build từ **`techx-corp-platform`**:

- **CI/CD (khuyến nghị):** push `main` → `techx-corp/*:sha-…`; branch `techx-dev-corp` → `techx-dev-corp/*:sha-…`
- **Thủ công:**

```bash
IMAGE_NAME=493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp \
IMAGE_VERSION=sha-manual DEMO_VERSION=sha-manual \
docker buildx bake -f docker-compose.yml --push \
  --set "*.platform=linux/amd64,linux/arm64"
```

Xác minh trước khi Helm:

```bash
aws ecr describe-images --repository-name techx-corp/ad --region us-east-1 --max-items 3
```

Ghi lại **VERSION** (tag) để ghi vào `values-prod.yaml` / `values-dev.yaml` (GitOps) — **không** chỉ giữ trên máy operator.

---

## Phase 4: Deploy (GitOps ưu tiên — REL-09)

> Chi tiết: [operations/gitops-argocd.md](./operations/gitops-argocd.md) · `gitops/README.md` · plan workspace `docs/gitops-argocd.md`

### 4A. Argo CD (sau khi control plane đã cài)

#### Contract GitOps (bắt buộc khớp)

| Môi trường | Manifests | Application | AppProject | Destination NS | Branch |
|---|---|---|---|---|---|
| **Dev** | `gitops/clusters/dev/` | `techx-corp-dev` | `techx-corp-dev` | `techx-corp-dev` | `techx-dev-corp` |
| **Prod** | `gitops/clusters/prod/` | `techx-corp` | `techx-corp` | `techx-corp-prod` | `main` |

- **Git source (cả hai env):** `https://github.com/tf2-team/tf2-corp-chart.git`
- AppProject `spec.sourceRepos` **phải** chứa đúng URL đó (HTTPS và/hoặc SSH).
- AppProject `spec.destinations` **phải** khớp `Application.spec.destination` (server + namespace).
- Value layer: `values.yaml` + `values-public-alb.yaml` + `values-dev|prod.yaml`.

#### Bootstrap (một lần / cluster)

```bash
# 1) Context đúng cluster (dev vs prod)
aws eks update-kubeconfig --region us-east-1 --name techx-dev   # or techx-tf2

# 2) Apply AppProject + Application (từ working copy chart)
kubectl apply -f gitops/clusters/dev/    # dev → techx-corp-dev
# kubectl apply -f gitops/clusters/prod/ # prod → techx-corp-prod

# 3) Hard refresh nếu UI còn stale error sau khi sửa project/repo
kubectl -n argocd annotate application techx-corp-dev \
  argocd.argoproj.io/refresh=hard --overwrite
```

Nếu repo **private**, đăng ký credential trước sync (một lần):

```bash
# ví dụ PAT / deploy key — chọn theo org policy
argocd repo add https://github.com/tf2-team/tf2-corp-chart.git \
  --username <user> --password <token>
```

#### Deploy / promote image tag

1. Cập nhật tag trong Git (cùng commit với mọi service bake):
   - Dev: `values-dev.yaml` → `default.image.tag` (branch `techx-dev-corp`)
   - Prod: `values-prod.yaml` → `default.image.tag` (branch `main`)
2. **Contract:** tag global — rebuild/push **toàn bộ** service bake với cùng tag; verify ECR trước merge PR.
3. Sync **đúng tên Application**:

```bash
# --- Development ---
argocd app diff techx-corp-dev
argocd app sync techx-corp-dev --dry-run
argocd app sync techx-corp-dev
argocd app wait techx-corp-dev --sync --health --timeout 600

# --- Production ---
argocd app diff techx-corp
argocd app sync techx-corp --dry-run
argocd app sync techx-corp
argocd app wait techx-corp --sync --health --timeout 600
```

Tương đương kubectl (khi không có CLI `argocd`):

```bash
kubectl -n argocd get application techx-corp-dev
kubectl -n argocd annotate application techx-corp-dev \
  argocd.argoproj.io/refresh=hard --overwrite
# Sync: Argo CD UI → Sync, hoặc argocd CLI
```

4. **Rollback chuẩn:** `git revert` commit deploy → merge → Argo sync.  
   History rollback Argo chỉ break-glass (tắt auto-sync → rollback → **cập nhật Git**).
5. Sau cutover: **không** `helm upgrade` thường xuyên (ownership = Argo CD).
6. First cutover (v1): **không** automated sync, **không** prune, **không** ServerSideApply.

#### Truy cập Argo CD UI / first admin (initial)

Không public Ingress (v1). Port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080
```

| Field | Value |
|---|---|
| **Username** | `admin` (fixed initial account) |
| **Password** | From Secret `argocd-initial-admin-secret` (namespace `argocd`) |

**Query first/initial admin password:**

```bash
# Bash / Git Bash / WSL
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

```powershell
# Windows PowerShell
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
  (kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}")
))
```

Infra Terraform helper (when `argocd_enabled=true` — prints the same kubectl query):

```bash
terraform -chdir=../techx-corp-infra/environments/development \
  output -raw argocd_admin_password_command
# run the printed command
```

Xoay password sau login đầu; secret `argocd-initial-admin-secret` có thể bị xóa sau khi đổi (query trên sẽ fail).
### 4B. Helm install / upgrade (break-glass + cold install)

> **Paths:** mọi lệnh dưới đây giả định **cwd = chart root** (local `techx-corp-chart` / clone `tf2-corp-chart`).  
> **Release name vs namespace:** phải khớp bảng hằng số (§2 / §4). Dev: release `techx-corp-dev` → NS `techx-corp-dev`. Prod: release `techx-corp` → NS `techx-corp-prod`.  
> **Sau cutover GitOps:** tắt Argo auto-sync trước khi `helm upgrade`. Argo **không** chuyển Helm release state; dual-drive gây lệch. Deploy thường xuyên qua Git (tag) + Argo sync (mục 4A).

#### B1. Install from nothing (cold install)

Thứ tự bắt buộc: ESO + `ClusterSecretStore` Ready → **secrets** release Ready → **app** chart.  
Prereqs: Phase 1–2 (cluster, ALB controller, ASM bootstrap, ESO) + Phase 3 (images trên ECR với tag sẽ ghi trong overlay).

**Development**

```bash
# 0) Context đúng cluster dev
aws eks update-kubeconfig --region us-east-1 --name techx-dev

# 1) Optional: pull chart dependencies (first time / after Chart.yaml change)
helm dependency build .

# 2) SEC-05: ExternalSecrets → K8s Secrets (wait Ready before app)
helm upgrade --install techx-corp-secrets ./secrets-chart \
  -n techx-corp-dev --create-namespace \
  -f secrets-chart/values.yaml \
  -f secrets-chart/values-dev.yaml
kubectl -n techx-corp-dev wait --for=condition=Ready externalsecret --all --timeout=120s

# 3) App chart (from nothing = same command as upgrade --install)
#    Set image tag in values-dev.yaml first:
#      default.image.tag: "sha-xxxxxxxx"
helm upgrade --install techx-corp-dev . \
  -n techx-corp-dev --create-namespace \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-dev.yaml \
  --wait --atomic --timeout 15m --history-max 10
```

**Production**

```bash
# 0) Context đúng cluster prod
aws eks update-kubeconfig --region us-east-1 --name techx-tf2

# 1) Optional
helm dependency build .

# 2) SEC-05 secrets
helm upgrade --install techx-corp-secrets ./secrets-chart \
  -n techx-corp-prod --create-namespace \
  -f secrets-chart/values.yaml \
  -f secrets-chart/values-prod.yaml
kubectl -n techx-corp-prod wait --for=condition=Ready externalsecret --all --timeout=120s

# 3) App chart
#    Set image tag in values-prod.yaml first (default.image.tag).
helm upgrade --install techx-corp . \
  -n techx-corp-prod --create-namespace \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-prod.yaml \
  --wait --atomic --timeout 15m --history-max 10
```

Local demo **không** ESO (plaintext only): thêm `-f values-demo.yaml` ở bước app chart; **không** dùng production.

**Sau cold install — kiểm tra nhanh**

```bash
# Dev examples (prod: -n techx-corp-prod, release techx-corp)
helm status techx-corp-dev -n techx-corp-dev
kubectl -n techx-corp-dev get deploy,pods,ingress
kubectl -n techx-corp-dev get deploy ad -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
bash scripts/smoke-test.sh --namespace techx-corp-dev
```

#### B2. Update image tag only

**Contract:** một **VERSION** global (`default.image.tag`) cho mọi nested bake service, **including** `opensearch`.

| File | Key |
|---|---|
| `values-dev.yaml` / `values-prod.yaml` | `default.image.tag` only |

Verify images exist on ECR **before** upgrade (mọi service bake, kể cả `opensearch`).

**Preferred (GitOps)** — không cần Helm sau cutover:

```bash
# 1) Edit overlay in Git (example dev):
#    default.image.tag: "sha-NEW"
# 2) Commit + push (dev branch techx-dev-corp / prod main)
# 3) Sync
argocd app diff techx-corp-dev          # or techx-corp
argocd app sync techx-corp-dev          # or techx-corp
argocd app wait techx-corp-dev --sync --health --timeout 600
```

**Break-glass Helm** — tag đã ghi trong overlay file, rồi upgrade lại cùng layer values (giống install):

```bash
# --- Development ---
# Edit values-dev.yaml: default.image.tag = sha-NEW
helm upgrade --install techx-corp-dev . \
  -n techx-corp-dev \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-dev.yaml \
  --wait --atomic --timeout 15m --history-max 10

# --- Production ---
# Edit values-prod.yaml: default.image.tag = sha-NEW
helm upgrade --install techx-corp . \
  -n techx-corp-prod \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-prod.yaml \
  --wait --atomic --timeout 15m --history-max 10
```

**Break-glass Helm** — set tag trên CLI (không sửa file):

```bash
# Development — replace sha-NEW
helm upgrade techx-corp-dev . \
  -n techx-corp-dev \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-dev.yaml \
  --set default.image.tag=sha-NEW \
  --wait --atomic --timeout 15m --history-max 10

# Production — replace sha-NEW
helm upgrade techx-corp . \
  -n techx-corp-prod \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-prod.yaml \
  --set default.image.tag=sha-NEW \
  --wait --atomic --timeout 15m --history-max 10
```

> **Không** dùng `--reuse-values` + chỉ `--set default.image.tag` khi base values trong Git đã đổi (ALB, resources, …): dễ lệch với overlay. Prefer full `-f` layer như trên.  
> Sau break-glass CLI tag: **đồng bộ lại Git** (ghi tag vào `values-dev|prod.yaml`) để Argo không revert.

**Xác minh tag mới**

```bash
# Dev
kubectl -n techx-corp-dev get deploy ad frontend checkout \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'

# Prod
kubectl -n techx-corp-prod get deploy ad frontend checkout \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
# Kỳ vọng: .../techx-dev-corp|techx-corp/<service>:sha-NEW
```

### Helm NOTES — Argo CD credential in ra sau install/upgrade

Khi `helm upgrade --install` **thành công**, chart in **NOTES** (cuối output), gồm block **ARGO CD DEFAULT ADMIN CREDENTIAL (initial admin)**:

- Username: `admin`
- Password: Helm `lookup` Secret `argocd/argocd-initial-admin-secret` (nếu còn trên cluster)
- **Luôn in** lệnh query first admin init:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Xem lại NOTES sau này:

```bash
helm get notes techx-corp-dev -n techx-corp-dev
# hoặc prod:
helm get notes techx-corp -n techx-corp-prod
```

> **Lưu ý:** `--dry-run=client` không đọc được secret (lookup rỗng). Cần kết nối cluster thật.  
> Secret biến mất sau khi đổi password admin — lúc đó chỉ còn cách reset password Argo CD (xem runbook GitOps).
### Ý nghĩa tham số an toàn

| Flag / value | Mục đích |
|---|---|
| `-f values-public-alb.yaml` | Public ALB Ingress cho `frontend-proxy` + route blocking |
| `-f values-dev\|prod.yaml` | REGISTRY/PROJECT + tag trong Git |
| `--wait` / Argo `app wait` | Chờ ready / health (timeout 10m) |
| `--atomic` | **Chỉ Helm**; Argo không có parity — partial sync có thể xảy ra |
| `--history-max 10` | Giới hạn revision history (Helm) |
| `metrics-server.enabled` | Default `true` trong `values.yaml`. Set `false` nếu cluster đã có Metrics Server (tránh conflict APIService / RBAC) |

### Subchart Metrics Server (HPA)

Chart dependency: **metrics-server 3.13.1** (`https://kubernetes-sigs.github.io/metrics-server/`), condition `metrics-server.enabled`.

| Value | Default | Ghi chú |
|---|---|---|
| `metrics-server.enabled` | `true` | Tắt nếu đã cài cluster-wide |
| `metrics-server.fullnameOverride` | `metrics-server` | Tên Deployment/Service trong release namespace |
| `metrics-server.args` | `--kubelet-insecure-tls` | Thường cần trên EKS (kubelet serving cert) |
| `metrics-server.resources` | requests 100m/200Mi, limit memory 200Mi | |

HPA templates (`templates/hpa.yaml`) dùng `autoscaling/v2` — **cần** Metrics Server (API `metrics.k8s.io`) cho CPU/memory. Request-rate (RPS) HPA **cần** Prometheus Adapter (API `external.metrics.k8s.io`), subchart `prometheus-adapter` (default `enabled: true`). Optional `autoscaling.behavior` (scale-up/down policies) is rendered when set. Multi-replica HPA services also get a first-party **PodDisruptionBudget** (`minAvailable: 1`) when `minReplicas >= 2`.

**Metric policy (Option B+ — triple metrics):**

| Metric | Target | Role |
|---|---:|---|
| **RPS** (External) | per-service `targetRequestsPerSecond` | Primary under traffic (I/O-bound / high-RPS low-CPU paths) |
| CPU | **70%** | Safety when load is compute-bound |
| Memory | **90%** | Safety valve only (near request / OOM-adjacent pressure) |

HPA desired replicas = **max** across metrics. A low memory target would dominate scale-out; 90% is intentional so idle heaps do not pin high replica counts. If idle memory utilization stays near request, **raise `requests.memory`** — do not lower the memory target to “fix” thrash. Hard OOM protection remains `limits` + runtime caps (e.g. `GOMEMLIMIT`).

RPS uses External metric `http_requests_per_second` with label `service_name` (OTel). Ops detail: `docs/operations/request-metric-hpa.md`.

**Default HPA inventory** (`components.*.autoscaling`):

| Service | min | max | Metrics | Placement |
|---|---:|---:|---|---|
| `frontend` | 1 | 6 | CPU 70% / Mem 90% / RPS **15** | Karpenter (spot-tolerant) |
| `checkout` | 1 | 6 | CPU 70% / Mem 90% / RPS **5** | Karpenter (spot-tolerant) |
| `cart` | 1 | 6 | CPU 70% / Mem 90% / RPS **20** | Karpenter (default) |
| `product-catalog` | 1 | 6 | CPU 70% / Mem 90% / RPS **30** | Karpenter (spot-tolerant) |
| `currency` | 1 | 6 | CPU 70% / Mem 90% / RPS **50** | Karpenter (spot-tolerant) |
| `recommendation` | 1 | 6 | CPU 70% / Mem 90% / RPS **15** | Karpenter (spot-tolerant) |
| `frontend-proxy` | 1 | 3 | CPU 70% / Mem 90% / RPS **40** | **Critical MNG** (cap max at 3) |

`load-generator` has **no HPA** (fixed `replicas` from chart default, typically 1). Ramp synthetic traffic via `LOCUST_USERS` / Locust UI — extra replicas with `LOCUST_AUTOSTART` would each run an independent swarm.

All HPA services use **`minReplicas: 1`** in base `values.yaml` (cost floor; scale-out still goes to max under load). First-party PDBs are only rendered when `minReplicas >= 2`, so none of these HPAs emit a PDB at the current floor.

**Critical capacity note:** `frontend-proxy` scale-out still lands only on Critical MNG (small floor). If extra proxy pods are `Pending`, free Critical capacity or adjust MNG size in infra — do not raise chart `maxReplicas` without capacity review.

**Prometheus Adapter:** pin Critical MNG; talks to in-cluster `http://prometheus:9090`. Disable with `prometheus-adapter.enabled: false` if you only want CPU/memory HPA.

### Kiểm tra image trong Pod

```bash
kubectl -n techx-corp-prod get deploy ad -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# Kỳ vọng: .../techx-corp/ad:sha-a1b2c3d
```

### Storefront ALB path blocking (toggle only)

Security posture on public ALB (`frontend-proxy-public`):

| | Paths |
|---|---|
| **ALLOWED** | `/`, `/api/*`, `/images/*` (catch-all `/` → frontend-proxy) |
| **BLOCKED** (HTTP 403) when ON | `/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`, `/otlp-http` |

Flag: `components.frontend-proxy.publicAlb.blockSensitivePaths`  
- Default in `values-public-alb.yaml`: **`true`**  
- Terraform source of truth (optional): `storefront_alb_block_sensitive_paths` in `techx-corp-infra`

If the Helm release is **already installed**, you do **not** need a full reinstall. Toggle **only** the block flag with `helm upgrade` + `--reuse-values` (keeps image repo/tag and other values):

**Turn blocking ON** (storefront-only; 403 on sensitive paths):

```bash
# cwd = chart root
helm upgrade techx-corp . \
  -n techx-corp-prod \
  --reuse-values \
  --set components.frontend-proxy.publicAlb.blockSensitivePaths=true \
  --wait --timeout 5m
```

**Turn blocking OFF** (all paths forward to frontend-proxy):

```bash
helm upgrade techx-corp . \
  -n techx-corp-prod \
  --reuse-values \
  --set components.frontend-proxy.publicAlb.blockSensitivePaths=false \
  --wait --timeout 5m
```

> Use the same chart path you used on install (chart root / clone of `tf2-corp-chart`).  
> ALB listener rules may take **1–2 minutes** to update after Ingress changes.

**Verify:**

```bash
# Ingress paths: with ON → /grafana (etc.) present; with OFF → only /
kubectl -n techx-corp-prod get ingress frontend-proxy-public -o yaml

ALB_DNS=$(kubectl get ingress frontend-proxy-public -n techx-corp-prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# ON  → HTTP 403 ;  OFF → not 403 (often 200/302/404 from app)
curl -i "http://${ALB_DNS}/grafana"
```

From Terraform (optional helper):

```bash
terraform -chdir=enviroments/production output storefront_alb_helm_set_flags
# → --set components.frontend-proxy.publicAlb.blockSensitivePaths=true|false
```

---

## Phase 5: Verification & Access

### ALB hostname

```bash
kubectl get ingress frontend-proxy-public -n techx-corp-prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

(DNS ALB có thể mất 2–5 phút.)

### Metrics Server & HPA

```bash
# Metrics Server pod (release namespace)
kubectl -n techx-corp-prod get deploy,pods -l app.kubernetes.io/name=metrics-server
kubectl -n techx-corp-prod rollout status deploy/metrics-server --timeout=120s

# API available (cluster-scoped)
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes | head -c 200; echo

# Resource metrics (after ~15–30s scrape)
kubectl top nodes
kubectl top pods -n techx-corp-prod

# Prometheus Adapter (request-rate External metrics)
kubectl -n techx-corp-prod get deploy,pods -l app.kubernetes.io/name=prometheus-adapter
kubectl get apiservice | grep -E 'custom.metrics|external.metrics'
kubectl get --raw /apis/external.metrics.k8s.io/v1beta1 | head -c 200; echo

# HPA + PDB for multi-replica autoscaled services
kubectl -n techx-corp-prod get hpa,pdb
kubectl -n techx-corp-prod describe hpa frontend checkout cart product-catalog currency recommendation frontend-proxy
```

Kỳ vọng: `TARGETS` không còn `<unknown>` sau khi Metrics Server Ready (CPU/mem); External RPS targets populate after traffic + Adapter Ready; `kubectl top` trả về CPU/memory; seven HPAs on base (`frontend`, `checkout`, `cart`, `product-catalog`, `currency`, `recommendation`, `frontend-proxy`) all with `MINPODS=1`; no `load-generator` HPA; first-party PDBs only if some HPA later raises `minReplicas >= 2`. See `docs/operations/request-metric-hpa.md`.

### Smoke test

```bash
# Port-forward / in-cluster path
bash scripts/smoke-test.sh --namespace techx-corp-prod

# Qua public ALB (gồm route-blocking)
ALB_DNS=$(kubectl get ingress frontend-proxy-public -n techx-corp-prod \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
bash scripts/smoke-test.sh --namespace techx-corp-prod --alb-host "$ALB_DNS"
```

Route nhạy cảm (`/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`, `/otlp-http`) qua ALB công cộng → **HTTP 403** khi `blockSensitivePaths=true` (xem mục *Storefront ALB path blocking* ở Phase 4).

---

## Phase 6: Rollback & Safety

```bash
helm history techx-corp -n techx-corp-prod
helm rollback techx-corp <REVISION> -n techx-corp-prod --wait --timeout 10m

kubectl -n techx-corp-prod rollout status deploy/frontend-proxy --timeout=300s
kubectl -n techx-corp-prod rollout status deploy/frontend --timeout=300s
kubectl -n techx-corp-prod rollout status deploy/checkout --timeout=300s
kubectl -n techx-corp-prod rollout status deploy/payment --timeout=300s

bash scripts/smoke-test.sh --namespace techx-corp-prod
```

Chi tiết rollout: `docs/operations/rollout-safety.md` (nếu có trong repo).

---

## Troubleshooting

### ErrImagePull / ImagePullBackOff

1. Image format đúng?

   ```text
   OK:  .../techx-corp/ad:sha-a1b2c3d
   BAD: .../techx-corp:sha-a1b2c3d-ad
   BAD: .../techx-corp:1.0-ad
   ```

2. Tag Helm khớp tag ECR?

   ```bash
   aws ecr list-images --repository-name techx-corp/ad --region us-east-1
   ```

3. `repository` chỉ là base project, không có `/ad` trong value `default.image.repository`.

4. Node IAM có quyền pull ECR.

### ALB / Ingress

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
kubectl describe ingress frontend-proxy-public -n techx-corp-prod
```

| Symptom | Fix |
|---|---|
| `failed to get VPC ID` / `ec2imds GetMetadata` / `context deadline exceeded` | Helm install missing `region`/`vpcId`. Re-run Terraform output `aws_load_balancer_controller_helm_command` (see Phase 1–2). |
| Controller Ready, Ingress no ADDRESS | Check subnet tags `kubernetes.io/role/elb=1` / `internal-elb=1`; Ingress class/annotations for ALB. |
| IRSA / AccessDenied in logs | SA must have `eks.amazonaws.com/role-arn` from Terraform ALB controller role. |

### ExternalSecrets / CreateContainerConfigError (SEC-05)

```bash
kubectl -n techx-corp-prod get externalsecret
kubectl -n techx-corp-prod describe externalsecret techx-corp-postgresql-app
kubectl get clustersecretstore aws-secretsmanager
kubectl -n external-secrets logs deploy/external-secrets --tail=50
```

| Symptom | Fix |
|---|---|
| ExternalSecret not Ready | ASM value missing / wrong key; IRSA on ESO SA; ClusterSecretStore region |
| `CreateContainerConfigError` / secret not found | Deploy `techx-corp-secrets` and `kubectl wait --for=condition=Ready` before app chart |
| Auth to ASM fails | Check ESO SA annotation `eks.amazonaws.com/role-arn` matches Terraform output |
| `another operation (install/upgrade/rollback) is in progress` | Helm release stuck `pending-install` / `pending-upgrade`. See infra DEPLOYMENT troubleshooting §5: `helm status` → `helm uninstall` → reinstall from `external_secrets_helm_command`. Do not start a second upgrade while pending. |

### Helm upgrade stuck

- Kiểm tra events: `kubectl -n techx-corp-prod get events --sort-by='.lastTimestamp' | tail -30`
- `--atomic` sẽ rollback khi timeout; xem `helm history`.

### Metrics Server / HPA

```bash
kubectl -n techx-corp-prod logs deploy/metrics-server --tail=50
kubectl get apiservice v1beta1.metrics.k8s.io -o yaml
kubectl -n techx-corp-prod get hpa
```

| Symptom | Fix |
|---|---|
| HPA `TARGETS` = `<unknown>` / `failed to get cpu utilization` | Metrics Server chưa Ready hoặc APIService not Available. Check deploy + logs; đợi 1–2 phút sau Ready. |
| `x509: cannot validate certificate` / kubelet TLS errors in logs | Giữ `args: [--kubelet-insecure-tls]` (default chart). Không bỏ trên EKS managed nodes trừ khi đã cấu hình trusted kubelet certs. |
| APIService create conflict / `already exists` | Cluster đã có Metrics Server (thường `kube-system`). Set `metrics-server.enabled: false` và upgrade/sync. |
| `kubectl top` → `Metrics API not available` | Pod CrashLoop / APIService False. `kubectl describe apiservice v1beta1.metrics.k8s.io`; fix readiness, network to kubelets. |
| Duplicate Metrics Server | Chỉ **một** Metrics Server per cluster. App chart default ON — tắt subchart nếu infra đã cài. |

Tắt subchart (cluster đã có Metrics Server):

```bash
# Break-glass Helm (cwd = chart root)
helm upgrade techx-corp . -n techx-corp-prod \
  --reuse-values --set metrics-server.enabled=false \
  --wait --timeout 5m

# GitOps: ghi metrics-server.enabled: false vào values-dev.yaml / values-prod.yaml rồi Argo sync
```

### Argo CD Application / AppProject

```bash
kubectl -n argocd get application,appproject
kubectl -n argocd get application techx-corp-dev -o yaml   # or techx-corp
kubectl -n argocd get appproject techx-corp-dev -o yaml
kubectl -n argocd annotate application techx-corp-dev \
  argocd.argoproj.io/refresh=hard --overwrite
```

| Symptom / message | Cause | Fix |
|---|---|---|
| `destination server '…' and namespace 'techx-corp-dev' do not match any of the allowed destinations in project 'techx-corp-dev'` | AppProject `destinations` namespace ≠ Application destination (thường còn `techx-corp` trên project dev) | Set AppProject destination namespace = `techx-corp-dev`; `kubectl apply -f gitops/clusters/dev/appproject.yaml` |
| `application repo https://github.com/tf2-team/tf2-corp-chart.git is not permitted in project '…'` | AppProject `sourceRepos` thiếu URL đúng, hoặc stale condition sau khi đổi repo | Thêm `tf2-corp-chart` vào `sourceRepos`; re-apply AppProject; hard-refresh Application |
| `failed to list refs: authentication required: Repository not found` | Sai `repoURL` (vd. `techx-corp-chart` không tồn tại) **hoặc** repo private thiếu credential | Dùng `https://github.com/tf2-team/tf2-corp-chart.git`; đăng ký `argocd repo add` nếu private |
| Application **OutOfSync** — diff chỉ có `argocd.argoproj.io/instance: <app-name>` | **Expected on Helm → Argo cutover.** Argo tracks ownership with label `application.instanceLabelKey` (default `argocd.argoproj.io/instance` = Application `metadata.name`). Helm live objects lack that label → every resource OutOfSync until first sync stamps it. **Not** a chart template bug; chart does not set this label. | Review `argocd app diff` (expect only that label on existing objects). Then **one** manual sync: `argocd app sync techx-corp-dev` (or prod `techx-corp`). After apply, tracking labels land and that noise disappears. Do **not** `ignoreDifferences` this label (breaks ownership/orphan detection). |
| Application **OutOfSync** sau bootstrap (other diffs) | Automated sync OFF (v1) **or** real drift (values/tag/templates) | `argocd app diff` then `argocd app sync techx-corp-dev` / `techx-corp` when intentional |
| Orphaned resources warning | Objects **in destination namespace** not rendered by this Application (warn only; not SyncFailed) | **Expected** on cutover: Helm `sh.helm.release*` Secrets, ESO Secrets/`ExternalSecret` (secrets-chart), StatefulSet PVCs, `kube-root-ca.crt`, `default` SA. AppProject `orphanedResources.ignore` lists these. Review UI list — only delete real junk; **never** prune PVCs/ESO secrets casually. v1 prune stays OFF. |
| Missing `APIService` / `RoleBinding` metrics-server (`kube-system`) | Subchart metrics-server not yet applied; or cluster already has metrics-server | First sync creates them **or** set `metrics-server.enabled: false` if cluster already has Metrics Server |
| `namespace kube-system is not permitted in project '…'` (RoleBinding `metrics-server-auth-reader`) | AppProject `destinations` only listed app namespace | Add destination `kube-system` to AppProject (see `gitops/clusters/*/appproject.yaml`) |
| `resource apiregistration.k8s.io:APIService is not permitted in project …` | AppProject `clusterResourceWhitelist` missing APIService | Whitelist `group: apiregistration.k8s.io` / `kind: APIService` (metrics-server subchart) |

> Sau khi sửa AppProject **và** Application, luôn hard-refresh nếu UI vẫn hiện error cũ.
>
> **Cutover note:** First successful sync of an existing Helm release mainly applies `argocd.argoproj.io/instance: techx-corp-dev` (dev Application name). That alone flips dozens of resources OutOfSync → Synced.

---

## Tài liệu liên quan

- GitHub chart: [`tf2-team/tf2-corp-chart`](https://github.com/tf2-team/tf2-corp-chart) (branch dev `techx-dev-corp`)  
- `gitops/clusters/dev|prod/` — Argo CD AppProject + Application  
- `gitops/README.md` — bootstrap tóm tắt  
- `techx-corp-platform/docs/CICD.md` — build/push OIDC  
- `techx-corp-platform/docs/DEPLOYMENT.md` — E2E đầy đủ  
- `techx-corp-infra` — nested ECR + IAM + SEC-05 ASM/ESO  
- [operations/external-secrets.md](./operations/external-secrets.md) — ESO bootstrap / cutover / rotation  
- `values.yaml` — `secretKeyRef` production path; `values-demo.yaml` for local plaintext; `metrics-server` subchart values  
- `secrets-chart/` — ExternalSecrets Helm release (`techx-corp-secrets`)  
- `Chart.yaml` — subchart deps (OTel, Prometheus, Grafana, Jaeger, OpenSearch, **metrics-server**)  
- `templates/NOTES.txt` — post-install notes (port-forward, ALB, **Argo CD admin credential**)  
- [operations/gitops-argocd.md](./operations/gitops-argocd.md) — GitOps runbook + UI access  
