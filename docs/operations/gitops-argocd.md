# Vận hành GitOps (Argo CD) — techx-corp-chart

## Mục tiêu

Git (`techx-corp-chart`) là nguồn sự thật; Argo CD đồng bộ namespace `techx-corp`.  
Sau cutover: **không** dùng `helm upgrade` thường xuyên.

## Truy cập UI (v1 — không public Ingress)

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# Admin password (xoay vòng sau login đầu):
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

## Bootstrap lần đầu

1. Terraform: `argocd_enabled = true` (dev trước) → apply.
2. Cấu hình credential repo Git trong namespace `argocd` (GitHub App / deploy key).
3. Cập nhật `values-dev.yaml` / `values-prod.yaml` **tag đang chạy thật** (giảm drift).
4. Apply manifests:

```bash
kubectl apply -f gitops/clusters/dev/   # hoặc prod/
```

5. Application bật **auto-sync + self-heal** (`prune: false`). Sau apply, Argo sẽ
   tự sync khi OutOfSync. Vẫn có thể force/review:

```bash
# Dev: techx-corp-dev / namespace techx-corp-dev
# Prod: techx-corp / namespace techx-corp
argocd app diff techx-corp-dev
argocd app sync techx-corp-dev --dry-run   # optional review
argocd app wait techx-corp-dev --sync --health --timeout 600
./scripts/smoke-test.sh --namespace techx-corp-dev
```

## Ownership sau cutover

Argo CD **quản lý** các resource hiện có. Trạng thái Helm release cũ **không** được chuyển sang Argo.  
Không còn dùng `helm upgrade` cho deploy thường. Break-glass: **tắt auto-sync** trước, rồi Helm nếu bắt buộc, sau đó **đồng bộ lại Git**.

## Rollback

### Chuẩn (primary)

```text
git revert <deployment-commit> → merge → Argo CD sync desired state cũ
```

### Break-glass: Argo History Rollback

Chỉ khi cần khẩn cấp:

1. Tắt automated sync trên Application.  
2. Argo CD History → Rollback.  
3. **Ghi cùng thay đổi vào Git** (revert/commit) để desired state khớp.  
4. Bật lại auto-sync (nếu đang dùng).

Nếu không cập nhật Git, Argo sẽ coi trạng thái rollback là **OutOfSync** và có thể ghi đè.

## Promote image tag

Contract chart: **một** `default.image.tag` cho **mọi** service nested (including `opensearch` as a first-party component).

```text
# Development (automated from platform CI)
Build ALL services with same tag (21-image release set, includes opensearch)
  → Push ECR
  → Verify every required repo has the tag (including PROJECT/opensearch)
  → release-ready
  → Platform job update-chart-dev direct-pushes values-dev.yaml
      (default.image.tag only) on branch techx-dev-corp
  → Argo CD Application techx-corp-dev auto-syncs

# Production (manual)
Build ALL services → verify ECR → release-ready
  → Open PR values-prod.yaml: default.image.tag only
  → Review / merge
  → Argo sync (+ wait 600s)
```

**Không** promote values song song khi push image chưa xong.  
Partial bake + global tag mới → `ImagePullBackOff`.

Dev automation lives in `techx-corp-platform` workflow `build-and-push.yml`.  
Full operator guide (PAT, secrets, branch rules): platform  
[`docs/CICD.md` § Operator setup — chart promote token](../../../techx-corp-platform/docs/CICD.md#4-operator-setup--chart-promote-token-dev-automation).

### Operator setup — automated dev tag promote (summary)

Platform CI cannot push to this chart repo with its default `GITHUB_TOKEN`. A PAT stored on the **platform** repo is required.

| Step | Where | Action |
|---|---|---|
| 1 | GitHub (user/machine) | Create **fine-grained PAT**: repository = this chart repo only; **Contents: Read and write**; finite expiry |
| 2 | **Platform** repo → Settings → Secrets → Actions | Secret name **`CHART_REPO_TOKEN`** = PAT value |
| 3 | Platform repo → Variables (optional) | `CHART_REPO` (default `tmcmanhcuong/tf2-corp-chart`), `CHART_BRANCH` (default `techx-dev-corp`) |
| 4 | **Chart** repo → branch/rulesets | Allow the PAT identity to **direct-push** `techx-dev-corp` (bypass “require PR” if it blocks the bot) |
| 5 | Platform Actions | Run **Build and push images** → `development` (or `src/**` push); confirm job **Update chart values-dev tag** green |
| 6 | Chart `values-dev.yaml` | Confirm `default.image.tag` equals the built `sha-<7char>` |

**Auth model (short):**

* Push authorization = **PAT owner / fine-grained grants** (not platform `GITHUB_TOKEN`).
* Commit author label in Git = `github-actions[bot]` (cosmetic).
* **Prod** is not automated; still open a manual PR for `values-prod.yaml`.

**If automation is not configured:** operators can still set `default.image.tag` manually on `techx-dev-corp` after platform `release-ready` is green.

### Gợi ý verify ECR (prod project)

```bash
TAG=sha-a1b2c3d
PROJECT=techx-corp   # or techx-dev-corp
for svc in ad cart checkout frontend frontend-proxy product-catalog opensearch; do
  aws ecr describe-images --repository-name "${PROJECT}/${svc}" \
    --image-ids imageTag="${TAG}" --region us-east-1 >/dev/null \
    && echo "OK ${PROJECT}/${svc}:${TAG}" \
    || echo "MISSING ${PROJECT}/${svc}:${TAG}"
done
```

(Mở rộng list đủ catalog bake 21 services trước khi merge prod.)

## Prod path protection

Required reviewers / CODEOWNERS không chỉ `values-prod.yaml`, mà cả:

- `templates/**`, `charts/**`
- `Chart.yaml`, `Chart.lock`
- `values.yaml`, `values-prod.yaml`, `values-public-alb.yaml`
- `gitops/clusters/prod/**`
- `postgresql/**` (và asset chart khác được render)

## Secrets

- Dev: có thể tạm giữ posture hiện tại với **risk acceptance** rõ.  
- Prod cutover: không commit credential thật mới; **ưu tiên hoàn thành SEC-05 (ESO)** trước.  
- Secret nên được tạo trên cluster (ESO), không nhét password production vào GitOps render.

## Auto-sync (mặc định)

**Dev và prod:** `automated.selfHeal: true`, `prune: false` trên Application
(`gitops/clusters/*/application.yaml`).

- Git commit → Argo reconcile → auto-apply khi OutOfSync.
- Live cluster drift bị self-heal (Git thắng).
- Resource xóa khỏi Git **không** bị prune tự động (an toàn; bật prune sau Phase 7 nếu cần).
- Tắt tạm: `argocd app set <APP> --sync-policy none` (hoặc sửa manifest / bỏ `automated`).

Không bật `ServerSideApply` trong baseline v1.

## Partial sync failure

Argo **không** có Helm `--atomic`. Failed sync có thể để lại trạng thái một phần.  
Hành động: `argocd app wait` / health; sửa Git; sync lại; hoặc Git revert.

## Orphan cleanup: OpenSearch subchart leftovers

OpenSearch was migrated from the official Helm subchart (`opensearch-3.6.0`) to a
first-party `components.opensearch` StatefulSet. With **`prune: false`**, Argo CD
will **not** delete the old subchart objects. They remain labeled
`argocd.argoproj.io/instance=<app>` and show as **OutOfSync / Orphaned**.

Identify leftovers (labels `helm.sh/chart: opensearch-3.6.0`):

| Kind | Name | Why orphaned |
|---|---|---|
| ConfigMap | `opensearch-config` | Subchart `opensearch.yml`; first-party uses env vars only |
| Service | `opensearch-headless` | Subchart discovery Service; first-party has ClusterIP `opensearch` only |
| PodDisruptionBudget | `opensearch-pdb` | Subchart PDB; first-party does not render a PDB |

One-time cleanup (dev example — adjust namespace for prod):

```bash
# Confirm chart label before delete
kubectl -n techx-corp-dev get cm,svc,pdb -l 'helm.sh/chart=opensearch-3.6.0'

kubectl -n techx-corp-dev delete configmap opensearch-config
kubectl -n techx-corp-dev delete service opensearch-headless
kubectl -n techx-corp-dev delete pdb opensearch-pdb

# Do not delete Service/StatefulSet named "opensearch" — that is the first-party workload.
argocd app get techx-corp-dev
# Expected: no longer OutOfSync for the three objects above
```

Also remove any other `helm.sh/chart=opensearch-3.6.0` objects (old StatefulSet,
NetworkPolicy, etc.) if present — only after confirming they are not the live
first-party resources (`helm.sh/chart: techx-corp-*`).

## Liên quan

- Workspace plan: `docs/gitops-argocd.md`
- Backlog: `docs/backlogs/2026-07-09-rel-09-gitops-argocd.md`
- Smoke: `scripts/smoke-test.sh`
