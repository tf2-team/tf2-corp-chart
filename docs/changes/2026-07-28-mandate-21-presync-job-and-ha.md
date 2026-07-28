# Change: Mandate 21 PreSync Migration Job, Linkerd HA, Drill Script, and Dashboard

## Summary

Created a Helm PreSync migration Job for Accounting database schema updates, configured 2 replicas and Directive 3 topology spread for Accounting in production, updated Linkerd GitOps Application with HA settings (`controllerReplicas: 2`, `enablePodAntiAffinity: true`, `enablePodDisruptionBudget: true`), ported the Mandate 21 FIS drill script, updated `maintenance-load-test.js` to emit streaming JSONL records with W3C traceparent headers, and added the Mandate 21 operational Grafana dashboard.

## Context

Mandate 21 requires database schema migration to execute automatically before workload pods update during GitOps sync. Production Accounting and Linkerd mesh control plane must meet high-availability standards to withstand fault injection drills without service interruption.

## Before

* Accounting lacked a PreSync database migration hook in Helm templates.
* Accounting production replicas were set to 1 without PDB or topology spread constraints.
* Linkerd control plane ran single-replica without anti-affinity or PDB.
* Load generator did not emit traceparent headers or structured JSONL drill records.

## After

* Added `templates/accounting-migration-job.yaml` with Argo CD `PreSync` hook annotations.
* Updated `values-prod.yaml` to run 2 Accounting replicas with Directive 3 topology spread and automatic PDB.
* Updated `gitops/linkerd/linkerd-control-plane.yaml` with HA settings and single `@hungxqt` change trail.
* Created `scripts/mandate21-fis-drill.ps1` in Chart repository with parameterized execution.
* Updated `scripts/maintenance-load-test.js` to inject `traceparent` and `x-test-request-id` headers and output JSONL logs.
* Added `grafana/provisioning/dashboards/mandate-21-durability.json`.

## Technical Design Decisions

* Used Argo CD `PreSync` hook delete policy `BeforeHookCreation` to ensure clean idempotency on every sync.
* Inherited existing Directive 3 topology spread (Zone maxSkew 1 ScheduleAnyway, Hostname maxSkew 1 minDomains 2 DoNotSchedule) for Accounting.
* Used standard W3C `traceparent` header (`00-{traceId}-{spanId}-01`) for end-to-end trace correlation in Jaeger.

## Implementation Details

1. Created `templates/accounting-migration-job.yaml`.
2. Updated `values-prod.yaml` to set `components.accounting.replicas: 2`.
3. Updated `gitops/linkerd/linkerd-control-plane.yaml` values.
4. Created `scripts/mandate21-fis-drill.ps1`.
5. Updated `scripts/maintenance-load-test.js`.
6. Created `grafana/provisioning/dashboards/mandate-21-durability.json`.

## Files Changed

* `templates/accounting-migration-job.yaml` — Created Accounting PreSync migration Job template.
* `values-prod.yaml` — Added 2 Accounting replicas for production.
* `gitops/linkerd/linkerd-control-plane.yaml` — Added controllerReplicas 2, pod anti-affinity, and PDB.
* `scripts/mandate21-fis-drill.ps1` — Ported Mandate 21 drill script into Chart repository.
* `scripts/maintenance-load-test.js` — Updated k6 script for traceparent injection and JSONL output.
* `grafana/provisioning/dashboards/mandate-21-durability.json` — Added Mandate 21 Grafana dashboard.
* `docs/changes/2026-07-28-mandate-21-presync-job-and-ha.md` — This change record.

## Dependencies and Cross-Repository Impact

* `techx-corp-platform`: Expects `--migrate-only` CLI argument in Accounting container.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Runs DB schema migration automatically before app deployment |
| **Infrastructure** | Increases Accounting replicas to 2; enables Linkerd HA |
| **Deployment** | Argo CD executes migration Job in PreSync phase |
| **Performance** | Zero runtime impact |
| **Security** | No secret exposure |
| **Reliability** | Eliminates downtime during database migration and single-node failures |
| **Cost** | Minimal additional pod memory/CPU footprint |
| **Backward compatibility** | Fully backward compatible |
| **Observability** | Adds Mandate 21 operational dashboard in Grafana |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint .` | ✅ Pass |

## Migration or Deployment Notes

Argo CD auto-sync will reconcile the chart and run the PreSync migration job before updating Accounting deployment.

## Risks and Rollback

**Rollback procedure:**
Revert commit in `techx-corp-chart`.

# Change trail: @hungxqt - 2026-07-28 - Mandate 21 Chart changes for PreSync migration Job, Linkerd HA, drill script, and dashboard.
