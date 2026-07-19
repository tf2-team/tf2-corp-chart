# Change: Temporarily Disable Mem0 in Production App Chart

## Summary

Set `mem0.enabled: false` in `values-prod.yaml` so the production app chart no longer deploys Mem0 workloads. Secrets-chart Mem0 ExternalSecrets overlays are **not** changed and remain enabled.

## Context

* Operator request: temporary disable of Mem0 in the app chart only.
* Base `values.yaml` already defaults `mem0.enabled: false`; production had turned it on.
* Keeping secrets-chart Mem0 targets avoids churn on ESO secrets while the workload is off.

## Before

* `values-prod.yaml`: `mem0.enabled: true` (Deployment, migrate Job, SA, Service, optional FastEmbed init, cleanup CronJob when configured).
* `secrets-chart/values-prod.yaml`: `mem0.enabled: true` (unchanged by this change).

## After

* `values-prod.yaml`: `mem0.enabled: false` with a temporary-disable comment.
* Mem0 templates under `templates/mem0.yaml` are gated on `.Values.mem0.enabled` and will not render.
* Secrets-chart Mem0 ExternalSecrets remain as previously configured.

## Technical Design Decisions

* **App chart only** — per operator request; secrets stay so re-enable is a single flag flip without re-wiring ASM keys.
* **Prod overlay only** — dev does not enable Mem0 in app values; no `values-dev` change.

## Implementation Details

1. Set `mem0.enabled: false` in `values-prod.yaml`.
2. Noted temporary intent and that secrets-chart is intentionally left alone.

## Files Changed

**Configuration:**
* `values-prod.yaml` — `mem0.enabled: false` (temporary).

**Documentation:**
* `docs/changes/2026-07-19-temporary-disable-mem0-prod.md` — This change record.

## Dependencies and Cross-Repository Impact

* None. Infra Mem0 RDS/IRSA untouched. Platform image bake still may publish `mem0`; chart simply does not deploy it.
* Related secrets remain: `secrets-chart/values-prod.yaml` Mem0 still enabled.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Mem0 API unavailable in prod namespace; callers depending on Mem0 will fail or skip |
| **Infrastructure** | No Terraform change; RDS may stay running (cost continues until infra scale-in) |
| **Deployment** | Argo prune/remove Mem0 Deployment/Job/etc. when auto-sync prune is on for those resources |
| **Performance** | Frees Mem0 pod CPU/memory |
| **Security** | No change to secret material; secrets may still exist via ESO |
| **Reliability** | Features that require Mem0 are offline until re-enabled |
| **Cost** | Small K8s compute savings; RDS/S3 cost unchanged by this flag |
| **Backward compatibility** | Temporary operational disable |
| **Observability** | Mem0 metrics/traces stop |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values flag | Inspect `mem0.enabled` in `values-prod.yaml` | ✅ `false` |
| Secrets untouched | Inspect `secrets-chart/values-prod.yaml` `mem0.enabled` | ✅ Still `true` |

### Manual Verification

* None in-cluster this session.

### Remaining Verification (Post-Merge)

1. Argo CD sync app chart; confirm Mem0 Deployment/Job gone (or scaled away) in `techx-corp-prod`.
2. Confirm secrets-chart still syncs `techx-corp-mem0` / master secret if desired.
3. Re-enable: set `mem0.enabled: true` and sync when ready.

## Migration or Deployment Notes

1. Merge/push chart; Argo auto-syncs app Application.
2. Do **not** change secrets-chart for this temporary disable.
3. To re-enable: flip `mem0.enabled` back to `true` in `values-prod.yaml` only.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Dependent features break without Mem0 | Medium | Medium | Accept temporary; re-enable when ready |
| Argo does not prune if prune disabled | Low | Low | Manual delete of Mem0 resources if needed |

**Rollback procedure:**

1. Set `mem0.enabled: true` in `values-prod.yaml`.
2. Commit/push; Argo sync.

<!-- Change trail: @hungxqt - 2026-07-19 - Record temporary mem0 disable in prod app chart only. -->
