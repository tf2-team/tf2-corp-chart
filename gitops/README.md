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
| `runtime-hardening` (prod only) | `gitops/runtime-hardening/overlays/audit`, `enforce`, then `enforce-clusterwide` | n/a | cluster-scoped |

`secrets-chart` is a **separate** Application from the main app chart so ExternalSecret
mapping changes auto-sync without waiting for a manual `helm upgrade`.

Root Applications reconcile **Application** and **AppProject** CRs only. They do **not**
deploy workload charts. Child Applications own store, secrets, admission policy,
and native Kubernetes runtime-hardening admission.

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
- **Default sync policy (app chart children):** `automated` with `selfHeal: true`,
  `prune: true` (dev + prod main Applications).
- **Secrets apps and root app-of-apps:** always `prune: false` (avoid deleting
  ExternalSecrets / Application CRs accidentally).
- **Primary rollback:** `git revert` → merge → Argo auto-syncs.
- **History rollback:** break-glass only; disable auto-sync; fix Git afterward.
- After cutover: do **not** routine `helm upgrade` for app **or** secrets releases (ownership is Argo CD).
- Global image tag: rebuild **all** services with the same tag before promotion PR.

See `docs/operations/gitops-argocd.md` and workspace `docs/gitops-argocd.md`.

## Native runtime-hardening policy

MANDATE-05 is migrating from Gatekeeper to Kubernetes
`ValidatingAdmissionPolicy`/`ValidatingAdmissionPolicyBinding`. The native policy
source is `gitops/runtime-hardening`; it creates no controller Pod, Service,
certificate, CRD, Load Balancer, or AWS resource.

The production Application starts at `overlays/audit` with `Warn,Audit`. Promote
its path to `overlays/enforce` only after VAP acceptance, zero live inventory,
and regression approval. Gatekeeper remains temporarily at `deny` during audit so
there is no admission gap, then moves to `dryrun` only for the native denial proof.

```cmd
argocd app wait runtime-hardening --sync --health --timeout 300
kubectl get validatingadmissionpolicies
kubectl get validatingadmissionpolicybindings
pwsh scripts\audit-runtime-hardening.ps1
```

Gatekeeper entries in the table are migration-only. Remove them, their source
paths, CRDs, webhook, workloads, Service, and namespace only after native Deny
passes CREATE/UPDATE fixtures. Follow
`docs/operations/runtime-hardening.md` for the ordered cutover and rollback.
<!-- Change trail: @hungxqt - 2026-07-18 - Add native VAP migration ownership. -->
