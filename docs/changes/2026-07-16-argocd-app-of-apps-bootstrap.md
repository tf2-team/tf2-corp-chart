# Change: Argo CD root app-of-apps bootstrap

## Summary

Introduced a durable root app-of-apps bootstrap under `gitops/bootstrap/{dev,prod}` so child Application and AppProject CRs in `gitops/clusters/{env}/` (store app, secrets, Gatekeeper) are reconciled by Argo CD instead of one-time `kubectl apply`. Hardened the Gatekeeper AppProject Namespace allow-list and kept the policy Application on manual sync until SEC-07 deny cutover.

## Context

Gatekeeper manifests existed under `gitops/clusters/prod/` but never appeared in the cluster because there is no app-of-apps path: only manually applied Application CRs are live. The same gap affected `techx-corp-secrets`. REL-09 Phase 7 deferred app-of-apps; this change implements the Application-ownership portion without ApplicationSet complexity.

## Before

* Operators applied individual YAMLs under `gitops/clusters/{env}/`.
* Syncing `techx-corp` only deployed the store chart (`path: .`).
* Gatekeeper Application/AppProject and often secrets Application were missing on prod.
* Gatekeeper AppProject lacked cluster-scoped `Namespace` for `CreateNamespace=true`.
* Gatekeeper policy Application used automated deny sync immediately when applied.

## After

* One-time bootstrap: `kubectl apply -f gitops/bootstrap/{env}/` creates `root-prod` / `root-dev` and `platform-root` / `platform-root-dev`.
* Root Application sources `gitops/clusters/{env}` (directory) into the `argocd` namespace with auto-sync, selfHeal, prune false.
* Child apps (including Gatekeeper controller) are Git-owned after root sync.
* Gatekeeper AppProject allows `Namespace` and aligned sourceRepos.
* `gatekeeper-policy` remains manual sync until SEC-07 dry-run cutover.

## Technical Design Decisions

* **Bootstrap outside managed path** (`gitops/bootstrap/` not under `clusters/`) avoids root self-management recursion.
* **App-of-apps over ApplicationSet** — two envs, few apps, simpler operator model.
* **Root prune false** — deleting a child YAML must not cascade-delete Applications in v1.
* **Policy manual sync** — production had known render violations; auto-deny on first bootstrap is unsafe.
* **No Helm dependency vendoring** for Gatekeeper in this change; rely on Argo `helm dependency build` + Chart.lock; vendor only if repo-server egress fails.

## Implementation Details

1. Added prod/dev root AppProject and Application manifests under `gitops/bootstrap/`.
2. Updated `gatekeeper-appproject.yaml` (Namespace whitelist, sourceRepos parity).
3. Set `gatekeeper-policy-application.yaml` to manual sync with cutover comments.
4. Rewrote GitOps/DEPLOYMENT/runtime-hardening/external-secrets/SEC-07 docs for root bootstrap.
5. Added this change document.

## Files Changed

**Bootstrap (new):**
* `gitops/bootstrap/prod/00-root-appproject.yaml` — `platform-root` (00- prefix for apply order).
* `gitops/bootstrap/prod/10-root-application.yaml` — `root-prod` sources `gitops/clusters/prod`.
* `gitops/bootstrap/dev/00-root-appproject.yaml` — `platform-root-dev`.
* `gitops/bootstrap/dev/10-root-application.yaml` — `root-dev` sources `gitops/clusters/dev`.

**Gatekeeper children:**
* `gitops/clusters/prod/gatekeeper-appproject.yaml` — Namespace + sourceRepos.
* `gitops/clusters/prod/gatekeeper-policy-application.yaml` — manual sync until cutover.

**Documentation:**
* `gitops/README.md`
* `docs/operations/gitops-argocd.md`
* `docs/operations/runtime-hardening.md`
* `docs/operations/external-secrets.md`
* `docs/DEPLOYMENT.md`
* `docs/adr/SEC-07-runtime-hardening.md`
* `docs/changes/2026-07-16-argocd-app-of-apps-bootstrap.md` — this record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-infra/docs/changes/2026-07-16-argocd-bootstrap-root-app.md` (Terraform bootstrap output strings).
* Related workspace: `docs/gitops-argocd.md` Phase 7 note.
* No Terraform resource changes for Gatekeeper.
* Cluster still needs one-time `kubectl apply` of bootstrap path after merge (mutating; operator-approved).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No store chart runtime change until root is applied and children sync |
| **Infrastructure** | No AWS resource change |
| **Deployment** | Bootstrap path is `gitops/bootstrap/{env}/` only |
| **Security** | Gatekeeper controller can be Git-owned; deny policy still staged |
| **Reliability** | Missing sibling Applications (secrets, Gatekeeper) self-heal from Git after root exists |
| **Backward compatibility** | Manual apply of child YAMLs still works but is non-preferred |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm dependency + template | `helm dependency build gatekeeper-chart` then `helm template` | ✅ Unique kinds include Deployment, ValidatingWebhookConfiguration, ClusterRole |
| YAML presence | List `gitops/bootstrap/**` and gatekeeper children | ✅ Files created |

### Manual Verification

* Code review of root AppProject whitelist (Application + AppProject only in `argocd`).
* Confirm root path is not under `gitops/clusters/*`.

### Remaining Verification (Post-Merge)

Operator-approved cluster steps:

```cmd
cd /d techx-corp-chart
kubectl apply -f gitops\bootstrap\prod\
argocd app wait root-prod --sync --health --timeout 300
kubectl -n argocd get applications,appprojects
argocd app wait gatekeeper --sync --health --timeout 600
kubectl -n gatekeeper-system get deploy,pod
argocd app get gatekeeper-policy
```

Expect `gatekeeper-policy` present without automated deny until cutover.

## Migration or Deployment Notes

1. Merge chart PR to the branch Argo tracks (`main` prod / `techx-dev-corp` dev).
2. Apply bootstrap once per cluster (CMD examples above).
3. Diff root Application vs live children before relying on selfHeal if live Application specs drifted from Git.
4. Do not enable automated on `gatekeeper-policy` until SEC-07 dry-run evidence is complete.
5. Stop documenting per-child `kubectl apply` as the primary bootstrap path.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Root selfHeal rewrites drifted Application specs | Medium | Medium | Review `argocd app diff root-prod` before first heal |
| Policy deny enabled too early | Low | High | Manual sync on policy Application |
| Helm dep fetch fails in repo-server | Low | Medium | Vendor chart follow-up |
| Root prune cascade | Low | High | prune false on root |

**Rollback procedure:**

1. Disable auto-sync on `root-prod` / `root-dev`.
2. Delete root Application if needed: `kubectl -n argocd delete application root-prod` (does not delete children when prune false).
3. Revert Git commit introducing bootstrap if desired.
4. Child Applications remain; re-apply children manually only if required.

### Apply-order fix (same change)

`root-application.yaml` sorts before `root-appproject.yaml` alphabetically, so
`kubectl apply -f gitops/bootstrap/prod/` created the Application one second before
the AppProject and left a sticky `InvalidSpecError`. Renamed to `00-` / `10-`
prefixes so AppProject always applies first.

### Gatekeeper policy CRD ordering (same change)

Constraint CRDs (`K8sContainerHardening`, etc.) are created asynchronously when
ConstraintTemplates are admitted. Argo dry-run of Constraints fails with "CRD not
installed" even when sync-waves put templates first. Fixed by:

* Template wave `0`, constraint wave `1`
* `SkipDryRunOnMissingResource=true` on each Constraint and on the policy Application
* Higher retry budget on `gatekeeper-policy`

<!-- Change trail: @hungxqt - 2026-07-16 - Fix Gatekeeper policy CRD dry-run ordering. -->
