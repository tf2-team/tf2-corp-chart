# GitOps manifests (Argo CD)

Cluster-specific Argo CD `AppProject` + `Application` manifests for the platform.

| Path | Cluster |
|------|---------|
| `clusters/dev/` | development EKS (`techx-dev`) |
| `clusters/prod/` | production EKS (`techx-tf2`) |

| Application (prod / dev) | Path | Helm release | Namespace |
|--------------------------|------|--------------|-----------|
| `techx-corp` / `techx-corp-dev` | `.` (root chart) | `techx-corp` / `techx-corp-dev` | `techx-corp-prod` / `techx-corp-dev` |
| `techx-corp-secrets` / `techx-corp-secrets-dev` | `secrets-chart` | `techx-corp-secrets` | same as app NS |
| Gatekeeper (prod only) | `gatekeeper-chart`, `gitops/gatekeeper` | see gatekeeper docs | `gatekeeper-system` |

`secrets-chart` is a **separate** Application from the main app chart so ExternalSecret
mapping changes auto-sync without waiting for a manual `helm upgrade`.

## Prerequisites

1. Argo CD installed (`argocd_enabled=true` in `techx-corp-infra`, or equivalent Helm).
2. Git repository credentials Secret in namespace `argocd` (GitHub App / deploy key / PAT).
3. ESO + `ClusterSecretStore` Ready before first secrets Application sync (SEC-05).
4. `values-dev.yaml` / `values-prod.yaml` image tags match **currently running** tags before first app sync.

## Bootstrap (once per cluster)

```bash
# Dev example — AppProject + app + secrets Applications
kubectl apply -f gitops/clusters/dev/

# Secrets first (ExternalSecrets Ready), then app chart
argocd app get techx-corp-secrets-dev
argocd app wait techx-corp-secrets-dev --sync --health --timeout 300
argocd app get techx-corp-dev
argocd app diff techx-corp-dev
# Applications use automated sync + selfHeal; optional first manual sync:
argocd app sync techx-corp-dev --dry-run
argocd app sync techx-corp-dev
argocd app wait techx-corp-dev --sync --health --timeout 600
```

Prod:

```bash
kubectl apply -f gitops/clusters/prod/appproject.yaml
kubectl apply -f gitops/clusters/prod/application.yaml
kubectl apply -f gitops/clusters/prod/secrets-application.yaml

argocd app wait techx-corp-secrets --sync --health --timeout 300
argocd app wait techx-corp --sync --health --timeout 600
```

Adopting an existing `techx-corp-secrets` Helm release: keep `releaseName: techx-corp-secrets`.
First sync may show OutOfSync only for Argo tracking labels until stamped — expected.

## Rules (REL-09)

- **No ServerSideApply** in v1 Application specs.
- **Default sync policy:** `automated` with `selfHeal: true`, `prune: false` (secrets apps always `prune: false`).
- **Primary rollback:** `git revert` → merge → Argo auto-syncs.
- **History rollback:** break-glass only; disable auto-sync; fix Git afterward.
- After cutover: do **not** routine `helm upgrade` for app **or** secrets releases (ownership is Argo CD).
- Global image tag: rebuild **all** services with the same tag before promotion PR.

See `docs/operations/gitops-argocd.md` and workspace `docs/gitops-argocd.md`.
<!-- Change trail: @hungxqt - 2026-07-15 - Document secrets-chart Argo Applications. -->

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
