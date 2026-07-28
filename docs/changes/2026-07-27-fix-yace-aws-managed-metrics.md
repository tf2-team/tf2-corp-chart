# Change: Widen YACE Managed Metric Lookback Window

## Summary

Widen the CloudWatch lookback window (`length`) from 300 seconds to 600 seconds for all static RDS, ElastiCache, and MSK metric exporter jobs in YACE. This ensures YACE tolerates standard CloudWatch 5-minute metric publication delays without emitting empty sample windows.

## Context

AWS CloudWatch managed-service metrics for RDS (`AWS/RDS`), MSK (`AWS/Kafka`), and ElastiCache for Valkey (`AWS/ElastiCache`) are published on 5-minute intervals. Due to normal publication lag, a 300-second lookback window frequently catches empty intervals between scrapes, causing Prometheus queries to report empty series or missing data.

## Before

In `values-prod.yaml`, YACE static jobs for `rds-postgresql`, `elasticache-cart-001`, `elasticache-cart-002`, and `kafka-broker-[1-3]` configured both `period: 300` and `length: 300`. This left zero safety margin for CloudWatch delivery latency.

## After

All static metric configurations retain `period: 300` but use `length: 600` (two evaluation periods). YACE retrieves the last 10 minutes of datapoints, ensuring a valid sample is always returned during OTel Prometheus scrapes.

## Technical Design Decisions

* **Lookback expansion vs polling frequency**: Kept `period: 300` and scrape interval at 30s; changed `length` to `600`. This avoids increasing CloudWatch `GetMetricData` API request volume while covering potential 5-minute publication jitter.
* **No `nilToZero` fallback**: Avoided setting `nilToZero: true` to prevent masking genuine AWS service outages as zero values.

## Implementation Details

1. Updated `components.yace.mountedConfigMaps` in `values-prod.yaml` to set `length: 600` across all metric entries under RDS, ElastiCache, and MSK broker static jobs.
2. Created chart validation test `tests/observability/verify-yace-aws-managed.ps1` to assert configuration parameters.

## Files Changed

**Configuration:**
* `values-prod.yaml` — Updated YACE static metric lookback window `length` from 300 to 600 and updated change trail comment.

**Tests:**
* `tests/observability/verify-yace-aws-managed.ps1` — Added automated contract verification for YACE static job configuration.

**Documentation:**
* `docs/changes/2026-07-27-fix-yace-aws-managed-metrics.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Related:** Workspace root query contract updates in `docs/changes/2026-07-27-fix-prometheus-aws-managed-queries.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change to application runtime logic. |
| **Infrastructure** | No change to AWS resources or IAM permissions. |
| **Deployment** | Argo CD automatically reconciles ConfigMap `yace-yace-config` upon Git push. |
| **Performance** | Minimal impact on YACE memory footprint; scrape latency unchanged. |
| **Security** | Preserves `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, and IRSA annotation. |
| **Reliability** | Eliminates false-positive metric gaps caused by CloudWatch publication lag. |
| **Cost** | No API cost increase (metric count and request rate remain unchanged). |
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Provides continuous series data for Prometheus instant/range queries. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Chart Contract | `pwsh -NoProfile -File tests\observability\verify-yace-aws-managed.ps1` | ✅ Pass |
| Helm Lint | `helm lint . -f values.yaml -f values-prod.yaml` | ✅ Pass |
| Helm Template | `helm template techx-corp . -n techx-corp-prod -f values.yaml -f values-prod.yaml` | ✅ Pass |

### Manual Verification

* Rendered YACE ConfigMap verified to contain `period: 300` and `length: 600` for all 6 static jobs.

### Remaining Verification (Post-Merge)

* Observe `kubectl -n techx-corp-prod logs deployment/yace` post Argo CD sync.

## Migration or Deployment Notes

None. Reconciliation is managed automatically by Argo CD.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| YACE exporter config syntax error | Low | Low | Helm lint and template pre-validation executed before commit. |

**Rollback procedure:**

Revert the Git commit in `techx-corp-chart`. Argo CD will reconcile the ConfigMap back to `length: 300`.

<!-- Change trail: @hungxqt - 2026-07-27 - Documented YACE lookback window change for AWS managed metrics. -->
