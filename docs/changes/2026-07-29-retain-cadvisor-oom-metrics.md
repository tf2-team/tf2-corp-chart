# Change: Retain cAdvisor OOM Event Metrics in Production Helm Values

## Summary

Update the `kubernetes-nodes-cadvisor` metric relabeling rules in `values-prod.yaml` to retain `container_oom_events_total` metrics alongside existing cAdvisor resource families for production workloads in `techx-corp-prod`. Add an automated observability verification script to enforce metric retention.

## Context

Prometheus scrape configuration for cAdvisor metrics in production (`values-prod.yaml`) previously omitted `container_oom_events_total` from the metric allowlist regex filter. Consequently, OOM kill events were dropped at ingestion despite existing catalog queries depending on this metric. Restoring ingestion enables container OOM tracking across all 16 production services without altering PromQL query semantics.

## Before

- `kubernetes-nodes-cadvisor` metric relabeling regex in `values-prod.yaml`:
  `container_(cpu_usage_seconds_total|memory_working_set_bytes|fs_reads_bytes_total|fs_writes_bytes_total|network_receive_bytes_total|network_transmit_bytes_total)`
- `container_oom_events_total` metrics were filtered out at scrape time.

## After

- `kubernetes-nodes-cadvisor` metric relabeling regex in `values-prod.yaml`:
  `container_(cpu_usage_seconds_total|memory_working_set_bytes|oom_events_total|fs_reads_bytes_total|fs_writes_bytes_total|network_receive_bytes_total|network_transmit_bytes_total)`
- `container_oom_events_total` series are retained for namespace `techx-corp-prod`.
- Automated test `tests/observability/verify-prometheus-resource-metrics.ps1` asserts retention.

## Technical Design Decisions

- Retain `container_oom_events_total` via the existing `kubernetes-nodes-cadvisor` metric_relabel_configs block to preserve namespace filter `techx-corp-prod` and scrape interval.
- Keep cumulative OOM counter PromQL semantics unchanged in `prometheus/prometheus_queries.json`.
- Direct Helm/kubectl mutations are prohibited; changes are delivered via GitOps/Argo CD auto-sync.

## Implementation Details

1. Added `tests/observability/verify-prometheus-resource-metrics.ps1` to assert `kubernetes-nodes-cadvisor` scrape configuration.
2. Updated `values-prod.yaml` metric keep regex to include `oom_events_total`.
3. Verified Helm chart syntax with `helm lint` and rendered templates with `helm template`.

## Files Changed

**Configuration:**
* `values-prod.yaml` — Added `oom_events_total` to cAdvisor metric allowlist and updated change trail comment.

**Tests:**
* `tests/observability/verify-prometheus-resource-metrics.ps1` — Created PowerShell test to verify cAdvisor resource metric allowlist.

**Documentation:**
* `docs/changes/2026-07-29-retain-cadvisor-oom-metrics.md` — Created this change record.

## Dependencies and Cross-Repository Impact

* Related: `docs/changes/2026-07-29-fix-prometheus-oom-and-add-catalog-validator.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change to application pods |
| **Infrastructure** | Ingests `container_oom_events_total` series in Prometheus |
| **Deployment** | GitOps sync via Argo CD |
| **Performance** | Negligible scrape overhead for 16 production services |
| **Security** | No change |
| **Reliability** | Restores OOM event visibility for anomaly detection and SLO tracking |
| **Cost** | Negligible TSDB storage increase |
| **Backward compatibility** | Fully backward-compatible |
| **Observability** | Enables `resource.oom_events_total` catalog queries across all production services |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Resource metrics test | `pwsh -NoProfile -File tests/observability/verify-prometheus-resource-metrics.ps1` | ✅ Pass |
| Helm lint | `helm lint . -f values.yaml -f values-prod.yaml` | ✅ Pass |
| Helm template | `helm template techx-corp . -n techx-corp-prod -f values.yaml -f values-prod.yaml` | ✅ Pass |

### Manual Verification

* Verified rendered Helm deployment manifest includes updated Prometheus configmap scrapings.

### Remaining Verification (Post-Merge)

* Verify Argo CD reconciles `techx-corp-chart` and Prometheus scrapes `container_oom_events_total` metrics in cluster.

## Migration or Deployment Notes

1. Merge PR for `techx-corp-chart`.
2. Argo CD will automatically sync changes to `techx-corp-prod`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Increased metric cardinality | Low | Low | Metric is low cardinality (one counter per container) |

**Rollback procedure:**

Revert commit in `techx-corp-chart` repository and push to Git. Argo CD will auto-sync the revert.

<!-- Change trail: @hungxqt - 2026-07-29 - Document cAdvisor oom_events_total retention and verification test. -->
