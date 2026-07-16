# GitOps manifests (Argo CD)

Cluster-specific Argo CD `AppProject` + `Application` manifests for the platform.

| Path | Role |
|------|------|
| `bootstrap/dev/` | **One-time** root AppProject + Application (dev) |
| `bootstrap/prod/` | **One-time** root AppProject + Application (prod) |
| `clusters/dev/` | Child apps managed by `root-dev` |
| `clusters/prod/` | Child apps managed by `root-prod` |

| Application (prod / dev) | Path | Helm release | Namespace |
|--------------------------|------|--------------|-----------|
| `root-prod` / `root-dev` | `gitops/clusters/{prod,dev}` (directory) | n/a (app-of-apps) | `argocd` |
| `techx-corp` / `techx-corp-dev` | `.` (root chart) | `techx-corp` / `techx-corp-dev` | `techx-corp-prod` / `techx-corp-dev` |
| `techx-corp-secrets` / `techx-corp-secrets-dev` | `secrets-chart` | `techx-corp-secrets` | same as app NS |
| `gatekeeper` (prod only) | `gatekeeper-chart` | `gatekeeper` | `gatekeeper-system` |
| `gatekeeper-policy` (prod only) | `gitops/gatekeeper` | n/a (kustomize/dir) | `gatekeeper-system` |

`secrets-chart` is a **separate** Application from the main app chart so ExternalSecret
mapping changes auto-sync without waiting for a manual `helm upgrade`.

Root Applications reconcile **Application** and **AppProject** CRs only. They do **not**
deploy workload charts. Child Applications own store, secrets, and Gatekeeper releases.

## Prerequisites

1. Argo CD installed (`argocd_enabled=true` in `techx-corp-infra`, or equivalent Helm).
2. Git repository credentials Secret in namespace `argocd` (GitHub App / deploy key / PAT).
3. ESO + `ClusterSecretStore` Ready before first secrets Application sync (SEC-05).
4. `values-dev.yaml` / `values-prod.yaml` image tags match **currently running** tags before first app sync.

## Bootstrap (once per cluster)

Apply **only** the root bootstrap path. Root self-heal then creates/updates child
Applications from `gitops/clusters/{env}/`. Do not rely on per-file `kubectl apply`
for children in steady state.

Filenames are ordered `00-root-appproject.yaml` then `10-root-application.yaml` so
directory apply creates the AppProject before the Application (avoids
`Application referencing project … which does not exist`). If that condition is
stale after a race, hard-refresh the root Application.

```cmd
cd /d techx-corp-chart

REM Dev
kubectl apply -f gitops\bootstrap\dev\
argocd app wait root-dev --sync --health --timeout 300
argocd app wait techx-corp-secrets-dev --sync --health --timeout 300
argocd app wait techx-corp-dev --sync --health --timeout 600
```

```cmd
cd /d techx-corp-chart

REM Prod
kubectl apply -f gitops\bootstrap\prod\
argocd app wait root-prod --sync --health --timeout 300
argocd app wait techx-corp-secrets --sync --health --timeout 300
argocd app wait techx-corp --sync --health --timeout 600
```

Adopting an existing `techx-corp-secrets` Helm release: keep `releaseName: techx-corp-secrets`.
First sync may show OutOfSync only for Argo tracking labels until stamped — expected.

Break-glass: disable auto-sync on the root Application before emergency edits to
child Application CRs; fix Git afterward.

## Rules (REL-09)

- **No ServerSideApply** in v1 Application specs.
- **Default sync policy (children):** `automated` with `selfHeal: true`, `prune: false`
  (secrets apps always `prune: false`). Root also uses `prune: false`.
- **Primary rollback:** `git revert` → merge → Argo auto-syncs.
- **History rollback:** break-glass only; disable auto-sync; fix Git afterward.
- After cutover: do **not** routine `helm upgrade` for app **or** secrets releases (ownership is Argo CD).
- Global image tag: rebuild **all** services with the same tag before promotion PR.

See `docs/operations/gitops-argocd.md` and workspace `docs/gitops-argocd.md`.

## Gatekeeper runtime-hardening policy

`tf2-corp-chart` owns the complete Kubernetes delivery for Gatekeeper. The
dedicated wrapper chart in `gatekeeper-chart` pins the upstream Gatekeeper Helm
chart and Argo CD installs it into `gatekeeper-system`. AWS infrastructure stays
outside this change. A separate Argo CD Application owns the
ConstraintTemplates and Constraints in `gitops/gatekeeper` so policy rollout can
wait for the controller and generated constraint CRDs to become ready.

After root-prod is applied, the **controller** Application (`gatekeeper`) is automated.
The **policy** Application (`gatekeeper-policy`) stays **manual sync** until SEC-07 cutover.

```cmd
cd /d techx-corp-chart

REM 1. Root already owns gatekeeper AppProject + controller Application.
argocd app wait gatekeeper --sync --health --timeout 600
kubectl -n gatekeeper-system rollout status deployment/gatekeeper-controller-manager
kubectl -n gatekeeper-system rollout status deployment/gatekeeper-audit

REM 2. Temporary dryrun policy from the reviewed revision.
pwsh scripts\render-gatekeeper-dryrun.ps1 -OutputPath gatekeeper-dryrun.yaml
kubectl apply -f gatekeeper-dryrun.yaml

REM 3. Confirm templates and dry-run constraints; retain checksum.
kubectl get constrainttemplates
kubectl get k8scontainerhardening,k8sallowedimagetags,k8srequiredresources
certutil -hashfile gatekeeper-dryrun.yaml SHA256

REM 4. After two clean audit cycles: enable automated on gatekeeper-policy via Git PR,
REM    then sync (or argocd app sync gatekeeper-policy once during cutover).
```

The committed source of truth keeps all three constraints at `deny`. Before enabling
policy Application auto-sync, render the reviewed revision, change only the temporary
output to `dryrun`, apply it, and wait for at least two 60-second audit cycles.
Enable automated policy only after every `status.totalViolations` is zero and
production smoke/SLO checks pass. Retain the temporary output checksum as evidence.
Roll back a false positive through the approved break-glass process; do not delete
the templates or disable flagd.
<!-- Change trail: @hungxqt - 2026-07-16 - Note AppProject-before-Application bootstrap order. -->
