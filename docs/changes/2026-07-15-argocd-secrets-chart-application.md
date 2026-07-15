# Change: Argo CD Applications for secrets-chart

## Summary

Added dedicated Argo CD Applications so the separate `secrets-chart` Helm release (`techx-corp-secrets`) is GitOps-managed with automated sync and self-heal, matching the main app chart pattern. ExternalSecret mapping changes (for example `FLAGD_SYNC_TOKEN`) now reconcile from Git without a manual `helm upgrade`.

## Context

The main Argo Applications (`techx-corp` / `techx-corp-dev`) use `path: .` and only render the root platform chart. `secrets-chart/` is a sibling chart historically installed with Helm as release `techx-corp-secrets`. Documentation already described Argo ownership of the secrets release, but no Application existed, so mapping updates in Git never auto-synced and the cluster ExternalSecret lagged (for example flagd-ui still mapping only `SECRET_KEY_BASE`).

* Why now: production ExternalSecret was stuck on an old Helm revision while ASM and Git already had the new key.
* Constraint: adopt the existing Helm release name `techx-corp-secrets` so live ExternalSecrets are not recreated under a new release.
* Pattern reference: `gatekeeper-application.yaml` (separate path + Application).

## Before

* Only main app (+ Gatekeeper) Applications existed under `gitops/clusters/{dev,prod}/`.
* Operators upgraded ExternalSecrets with `helm upgrade --install techx-corp-secrets ./secrets-chart ...`.
* AppProject orphaned-resource ignores treated ExternalSecrets as non-chart noise for the main app only.
* Docs mixed “let Argo sync secrets” language with Helm-only install steps.

## After

* Prod Application `techx-corp-secrets`: `path: secrets-chart`, value files `values.yaml` + `values-prod.yaml`, destination `techx-corp-prod`, `releaseName: techx-corp-secrets`, automated sync, `selfHeal: true`, `prune: false`.
* Dev Application `techx-corp-secrets-dev`: same chart path, `values-dev.yaml`, destination `techx-corp-dev`, same Helm release name, same sync policy.
* AppProjects document dual Application ownership.
* Ops docs prefer Argo bootstrap/sync; Helm remains break-glass only.

## Technical Design Decisions

* **Same AppProject as the app chart** (not a new project): destinations and sourceRepos already match; secrets only emit namespaced ExternalSecrets.
* **`prune: false` on secrets apps** even when dev app chart uses prune true — accidental ExternalSecret deletion is higher risk than drift cleanup for this chart.
* **`releaseName: techx-corp-secrets` on both envs** — matches historical Helm installs; Argo Application `metadata.name` differs on dev for uniqueness in the `argocd` namespace.
* **Keep ExternalSecret orphan ignores on the main project** — dual ownership in one namespace; ESO-generated Secrets remain ignored because ESO creates them outside the chart render.
* **No ServerSideApply** — same v1 baseline as other Applications.
* Alternative rejected: fold secrets templates into the root chart (larger blast radius, couples secret mapping to every app sync).

## Implementation Details

1. Added `gitops/clusters/prod/secrets-application.yaml` for production.
2. Added `gitops/clusters/dev/secrets-application.yaml` for development (dev repo URL + `techx-dev-corp` revision, consistent with `application.yaml`).
3. Updated AppProject header/orphan comments for dual Application ownership.
4. Updated `gitops/README.md`, `docs/operations/external-secrets.md`, `docs/operations/gitops-argocd.md`, and `docs/DEPLOYMENT.md` with bootstrap order (secrets Application before app) and break-glass Helm notes.
5. Operator still must **apply the Application CR once** per cluster (`kubectl apply -f .../secrets-application.yaml`); thereafter Git changes auto-sync.

## Files Changed

**GitOps:**
* `gitops/clusters/prod/secrets-application.yaml` — New prod secrets Application.
* `gitops/clusters/dev/secrets-application.yaml` — New dev secrets Application.
* `gitops/clusters/prod/appproject.yaml` — Ownership comments / change trail.
* `gitops/clusters/dev/appproject.yaml` — Ownership comments / change trail.
* `gitops/README.md` — Application inventory and bootstrap order.

**Documentation:**
* `docs/operations/external-secrets.md` — GitOps ownership table and Phase 2c bootstrap.
* `docs/operations/gitops-argocd.md` — Dual Application ownership and bootstrap order.
* `docs/DEPLOYMENT.md` — Prefer Argo for secrets-chart; Helm as break-glass.
* `docs/changes/2026-07-15-argocd-secrets-chart-application.md` — This change record.

## Dependencies and Cross-Repository Impact

* Requires existing ESO install + `ClusterSecretStore` `aws-secretsmanager` (infra / prior SEC-05 work).
* No `techx-corp-infra` or `techx-corp-platform` code change.
* Operators must merge this chart repo change and apply the new Application manifest once; Argo must already have credentials for the same Git repos as the main apps.

None for other repositories' code.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No direct runtime change until Application is applied; after sync, ExternalSecret specs track Git (e.g. flagd `FLAGD_SYNC_TOKEN` mapping). |
| **Infrastructure** | No Terraform change |
| **Deployment** | Secrets path becomes Argo-owned; one-time Application bootstrap required |
| **Performance** | Negligible (extra Argo Application reconcile) |
| **Security** | Improves consistency of secret *mappings* from Git; secret *values* remain ASM out-of-band |
| **Reliability** | Self-heal reduces long-lived drift between Git ExternalSecret and cluster |
| **Cost** | None |
| **Backward compatibility** | Adopts existing Helm release name; first sync may only stamp Argo labels |
| **Observability** | New Argo app visible as `techx-corp-secrets` / `techx-corp-secrets-dev` |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Secrets chart template (prod) | `helm template techx-corp-secrets ./secrets-chart -f secrets-chart/values.yaml -f secrets-chart/values-prod.yaml` | Run by operator/CI; chart unchanged this change |
| YAML structure | Manual review of Application manifests against existing Application specs | ✅ Manifest fields match project conventions |

### Manual Verification

* Confirmed main app Application `path: .` does not include `secrets-chart`.
* Confirmed secrets Application uses same repoURL/targetRevision conventions as sibling apps (prod `tf2-team`/`main`, dev `tmcmanhcuong`/`techx-dev-corp`).

### Remaining Verification (Post-Merge)

* Operator: apply prod Application, wait sync/health, confirm ExternalSecret `techx-corp-flagd-ui` `spec.data` includes `FLAGD_SYNC_TOKEN`, then key-name-only Secret check.
* Operator: same on dev if that cluster uses secrets-chart.
* Operator: confirm Argo UI shows `Synced`/`Healthy` for the new Application; no unexpected prune of existing ExternalSecrets (`prune: false`).

## Migration or Deployment Notes

1. Prerequisites: ESO + ClusterSecretStore Ready; Git credentials already work for the main app Application.
2. Merge this change to the branch Argo tracks (`main` / `techx-dev-corp`).
3. Bootstrap once:

```cmd
REM Production
kubectl apply -f gitops/clusters/prod/secrets-application.yaml
argocd app wait techx-corp-secrets --sync --health --timeout 300
kubectl -n techx-corp-prod get externalsecret techx-corp-flagd-ui -o jsonpath="{range .spec.data[*]}{.secretKey}{'\n'}{end}"
```

```cmd
REM Development
kubectl apply -f gitops/clusters/dev/secrets-application.yaml
argocd app wait techx-corp-secrets-dev --sync --health --timeout 300
```

4. After Healthy: stop routine `helm upgrade` for `techx-corp-secrets`.
5. If flagd Secret still lacks a property, fix ASM out-of-band, then annotate ExternalSecret `force-sync` (ESO), not Helm.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| First sync rewrites ExternalSecrets and briefly disrupts ESO | Low | Medium | `releaseName` matches existing release; `prune: false`; review `argocd app diff` before relying on auto-sync |
| Application not applied; Git changes still not deploy | Medium | Medium | Document one-time `kubectl apply`; verify Application exists in Argo UI |
| Wrong repo/branch on dev | Low | High | Match existing `techx-corp-dev` Application sourceRepos |
| Operator continues Helm upgrades → thrash with Argo self-heal | Medium | Medium | Docs mark Helm as break-glass only |

**Rollback procedure:**

1. Disable auto-sync on Application `techx-corp-secrets` / `techx-corp-secrets-dev`.
2. Delete the Application CR if abandoning GitOps for secrets (does not delete namespaced resources unless cascade finalizer is set — these Applications have no cascade finalizer).
3. Revert this Git commit and/or restore ExternalSecrets via break-glass `helm upgrade` only if needed.
4. Re-enable GitOps ownership by re-applying the Application when ready.

<!-- Change trail: @hungxqt - 2026-07-15 - Recorded Argo CD secrets-chart Application GitOps cutover. -->
