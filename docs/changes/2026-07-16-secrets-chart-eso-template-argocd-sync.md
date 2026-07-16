# Change: secrets-chart ESO templates to clear Argo CD OutOfSync

## Summary

Every ExternalSecret in `secrets-chart` now sets `target.template.engineVersion: v2` so ESO does not copy Argo CD / Helm tracking labels onto generated Kubernetes Secrets. That stops Application `techx-corp-secrets` from reporting permanent OutOfSync on Secrets that require pruning while `prune: false` keeps health green.

## Context

Production Application `techx-corp-secrets` was **Healthy** but **OutOfSync**. All ExternalSecrets were Synced; seven ESO-generated Secrets (`techx-corp-flagd-ui`, `grafana-admin`, `grafana-discord`, `opensearch`, `postgresql-admin`, `product-reviews`, `valkey-cart`) showed `requiresPruning: true` / `OutOfSync`.

* Why now: operators see a false drift signal on the SEC-05 secrets app after GitOps cutover.
* Constraint: must not enable prune (would delete live credential Secrets); must not fold Secrets into the Helm chart desired set.
* Cluster ESO version: **v0.14.4** (behavior confirmed in upstream `setMetadata`: labels copy only when `target.template` is nil).
* Evidence: `techx-corp-postgresql-app` already used a data template and only carried `reconcile.external-secrets.io/managed` — it was never listed as OutOfSync.

## Before

* Most ExternalSecrets had no `target.template`.
* ESO merged ExternalSecret `metadata.labels` / annotations onto each Secret, including `argocd.argoproj.io/instance: techx-corp-secrets` and Helm meta.
* Argo tracked those Secrets as app inventory; they are not in Git desired manifests → OutOfSync + requiresPruning.
* Sync result messages: `ignored (requires pruning)` because `prune: false`.

## After

* All ExternalSecrets (including those with only `spec.data` key maps) set:

  ```yaml
  target:
    template:
      engineVersion: v2
  ```

* Empty `template.data` still materializes provider keys from `spec.data` / `dataFrom` (ESO default when no data template is defined).
* `postgresql-app` keeps its existing DSN `template.data` block (already had `engineVersion: v2`).
* Chart version **0.1.1 → 0.1.2**.
* Ops runbook documents the OutOfSync root cause, verification, and optional one-time label cleanup if stale labels remain outside ESO managed fields.

## Technical Design Decisions

* **Minimal template block (not full pass-through `template.data`)** — ESO v0.14 already inserts `dataMap` when `template.data` is empty; avoids duplicating every key as `{{ .KEY }}` and reduces drift risk on key renames.
* **No `IgnoreExtraneous` annotations on ExternalSecrets** — would work if copied, but template-based non-propagation is the correct ownership model (Argo owns ExternalSecrets; ESO owns Secrets).
* **No AppProject / Application prune changes** — prune stays false; fixing tracking is safer than pruning orphans.
* **No ServerSideApply / resource exclusions in argocd-cm** — cluster-wide config is broader than this release needs.
* Alternative rejected: declare placeholder Secret manifests in Git — fights ESO ownership and risks overwriting credential data.

## Implementation Details

1. Updated `secrets-chart/templates/externalsecrets.yaml` header comment with Argo/ESO label-propagation notes.
2. Added `template.engineVersion: v2` under `target` for postgresql-admin, flagd-ui, product-reviews, grafana-admin, opensearch, valkey-cart, grafana-discord.
3. Left postgresql-app DSN template unchanged (already correct pattern).
4. Bumped `secrets-chart/Chart.yaml` to `0.1.2`.
5. Extended `docs/operations/external-secrets.md` with sync-status diagnosis and verification commands.
6. After merge, Argo auto-syncs ExternalSecrets; ESO re-reconciles and drops managed tracking labels from Secrets.

## Files Changed

**Chart:**
* `secrets-chart/templates/externalsecrets.yaml` — `target.template.engineVersion: v2` on all ExternalSecrets.
* `secrets-chart/Chart.yaml` — version 0.1.2.

**Documentation:**
* `docs/operations/external-secrets.md` — Argo OutOfSync section and verification / optional label cleanup.
* `docs/changes/2026-07-16-secrets-chart-eso-template-argocd-sync.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only; no infra or platform changes. Requires ESO ≥ 0.14 template metadata behavior (cluster already on 0.14.4).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change to secret key names, ASM paths, or pod env wiring |
| **Infrastructure** | No change |
| **Deployment** | Argo auto-sync of `techx-corp-secrets` after merge; no Helm break-glass needed |
| **Performance** | Negligible (one-time ESO reconcile per ExternalSecret) |
| **Security** | Unchanged; still Orphan creationPolicy; no secret payloads in Git |
| **Reliability** | Removes false OutOfSync; reduces risk of operators “fixing” via prune |
| **Cost** | None |
| **Backward compatibility** | Fully compatible; key sets unchanged |
| **Observability** | Argo app expected to move to Synced once Secret labels drop |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (prod values) | `helm lint ./secrets-chart -f secrets-chart/values.yaml -f secrets-chart/values-prod.yaml` | ✅ Pass |
| Helm template (prod) | `helm template techx-corp-secrets ./secrets-chart -f secrets-chart/values.yaml -f secrets-chart/values-prod.yaml` | ✅ All 8 ExternalSecrets include `engineVersion: v2` |
| Helm template (dev) | `helm template ... -f values-dev.yaml` | ✅ 7 ExternalSecrets (valkey disabled) include template |

### Manual Verification

* Confirmed live OutOfSync set against cluster Application status before the change.
* Confirmed ESO v0.14.4 `setMetadata` only copies ES labels when `template == nil`.

### Remaining Verification (Post-Merge)

1. Merge to `main` (prod chart remote `tf2-corp-chart`).
2. Wait: `argocd app wait techx-corp-secrets --sync --health --timeout 300` (or kubectl Application status).
3. Confirm ExternalSecrets Ready.
4. Confirm Secrets no longer have `argocd.argoproj.io/instance`.
5. Confirm Application sync status `Synced`.
6. If any tracking labels remain, run the documented `kubectl label secret ... argocd.argoproj.io/instance-` cleanup (cluster mutation; operator approval).

## Migration or Deployment Notes

1. Merge this chart change via the normal Git workflow (Argo auto-sync).
2. Do **not** run routine `helm upgrade` for `techx-corp-secrets` after cutover.
3. Do **not** set `prune: true` to clear OutOfSync.
4. Optional break-glass label cleanup only if post-sync Secrets still show the Argo instance label.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| ESO reconcile fails after template added | Low | Medium | Chart is minimal; empty template.data is supported on 0.14; check ExternalSecret status |
| Stale labels remain; still OutOfSync | Medium | Low | Documented one-time label removal; no data change |
| Operator enables prune to force Synced | Low | High | Docs explicitly forbid; prune remains false in Git |

**Rollback procedure:**

1. Revert this commit on the chart repo `main`.
2. Allow Argo to re-sync ExternalSecrets without the new template blocks.
3. Note: Secrets may re-acquire tracking labels and return to OutOfSync (previous behavior).

<!-- Change trail: @hungxqt - 2026-07-16 - ESO target.template on all secrets-chart ExternalSecrets for Argo sync hygiene. -->
