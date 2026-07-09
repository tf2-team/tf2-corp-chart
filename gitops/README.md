# GitOps manifests (Argo CD)

Cluster-specific Argo CD `AppProject` + `Application` for the `techx-corp` Helm chart.

| Path | Cluster |
|------|---------|
| `clusters/dev/` | development EKS (`techx-dev`) |
| `clusters/prod/` | production EKS (`techx-tf2`) |

## Prerequisites

1. Argo CD installed (`argocd_enabled=true` in `techx-corp-infra`, or equivalent Helm).
2. Git repository credentials Secret in namespace `argocd` (GitHub App / deploy key / PAT).
3. `values-dev.yaml` / `values-prod.yaml` image tags match **currently running** tags before first sync.

## Bootstrap (once per cluster)

```bash
# Dev example
kubectl apply -f gitops/clusters/dev/

argocd app get techx-corp
argocd app diff techx-corp
argocd app sync techx-corp --dry-run
argocd app sync techx-corp
argocd app wait techx-corp --sync --health --timeout 600
```

## Rules (REL-09)

- **No ServerSideApply** in v1 Application specs.
- First cutover: **no** automated sync, **no** prune.
- **Primary rollback:** `git revert` → merge → Argo sync.
- **History rollback:** break-glass only; disable auto-sync; fix Git afterward.
- After cutover: do **not** routine `helm upgrade` (ownership is Argo CD).
- Global image tag: rebuild **all** services with the same tag before promotion PR.

See `docs/operations/gitops-argocd.md` and workspace `docs/gitops-argocd.md`.
