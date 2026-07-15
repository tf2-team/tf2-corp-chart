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

argocd app get techx-corp-dev
argocd app diff techx-corp-dev
# Applications use automated sync + selfHeal; optional first manual sync:
argocd app sync techx-corp-dev --dry-run
argocd app sync techx-corp-dev
argocd app wait techx-corp-dev --sync --health --timeout 600
```

## Rules (REL-09)

- **No ServerSideApply** in v1 Application specs.
- **Default sync policy:** `automated` with `selfHeal: true`, `prune: false`.
- **Primary rollback:** `git revert` → merge → Argo auto-syncs.
- **History rollback:** break-glass only; disable auto-sync; fix Git afterward.
- After cutover: do **not** routine `helm upgrade` (ownership is Argo CD).
- Global image tag: rebuild **all** services with the same tag before promotion PR.

See `docs/operations/gitops-argocd.md` and workspace `docs/gitops-argocd.md`.

## Gatekeeper runtime-hardening policy

`tf2-corp-chart` owns the complete Kubernetes delivery for Gatekeeper. The
dedicated wrapper chart in `gatekeeper-chart` pins the upstream Gatekeeper Helm
chart and Argo CD installs it into `gatekeeper-system`. AWS infrastructure stays
outside this change. A separate Argo CD Application owns the
ConstraintTemplates and Constraints in `gitops/gatekeeper` so policy rollout can
wait for the controller and generated constraint CRDs to become ready.

Bootstrap production in this order:

```bash
# 1. Bootstrap the controller chart and wait for Gatekeeper to become ready.
kubectl apply -f gitops/clusters/prod/gatekeeper-appproject.yaml
kubectl apply -f gitops/clusters/prod/gatekeeper-application.yaml
kubectl -n gatekeeper-system rollout status deployment/gatekeeper-controller-manager
kubectl -n gatekeeper-system rollout status deployment/gatekeeper-audit

# 2. Render and apply temporary dryrun policy from the reviewed revision.
pwsh scripts/render-gatekeeper-dryrun.ps1 -OutputPath gatekeeper-dryrun.yaml
kubectl apply -f gatekeeper-dryrun.yaml

# 3. Confirm templates and dry-run constraints are healthy; retain the checksum.
kubectl get constrainttemplates
kubectl get k8scontainerhardening,k8sallowedimagetags,k8srequiredresources
sha256sum gatekeeper-dryrun.yaml

# 4. After two clean audit cycles, bootstrap the final deny source of truth.
kubectl apply -f gitops/clusters/prod/gatekeeper-policy-application.yaml
```

The committed source of truth keeps all three constraints at `deny`. Before this
policy Application is bootstrapped, render the reviewed revision, change only the
temporary output to `dryrun`, apply it, and wait for at least two 60-second audit
cycles. Bootstrap the policy Application only after every `status.totalViolations` is
zero and production smoke/SLO checks pass. Retain the temporary output checksum
as evidence. Roll back a false positive through the approved break-glass process;
do not delete the templates or disable flagd.
