# M16 temporary OpenSearch capacity and telemetry containment

## Why this exists

During the sustained 1000-user load test, the `otel-logs-*` OpenSearch
index reached the flood-stage disk watermark. OpenSearch changed the index to
`read-only-allow-delete`; OTel Collector retried and queued rejected logs until
its shared memory limiter rejected `spanmetrics`. Grafana then had gaps in the
checkout p95/p99 series even while application traffic continued.

This temporary profile exists only to collect long-running, high-load AI test
evidence without allowing a log-store outage to erase latency telemetry.

## Temporary changes

- Expand the existing OpenSearch PVC from 10Gi to 30Gi with a one-time
  Kubernetes PVC patch. This must not be placed in the StatefulSet
  `volumeClaimTemplates`: that field is immutable after the StatefulSet exists
  and would make Argo CD sync fail.
- Install an OpenSearch ISM policy for `otel-logs-*`; daily indices transition
  to deletion after three days. The bootstrap Job attaches the policy to
  existing indices and the hourly CronJob keeps the policy present.
- Bound the OpenSearch logs exporter to a 128-batch queue and 30 seconds of
  retry. Logs are intentionally best-effort during an OpenSearch outage;
  traces and spanmetrics must remain available for M16 SLO evidence.

## Required rollback after M16

Remove `values-m16-observability-load.yaml` from the production Argo CD
Application and delete the temporary retention template/CronJob after the M16
experiment. Restore the normal OpenSearch exporter retry and queue settings.

PVC expansion is **not reversible in place** on EBS/Kubernetes. Returning the
existing 30Gi claim to 10Gi requires a planned data migration or replacement
of the OpenSearch data volume; simply reverting Helm values cannot shrink it.
Do not remove the temporary profile until that storage decision is recorded.

The PVC expansion is intentionally user-executed after the retention profile
syncs successfully:

```powershell
wsl kubectl -n techx-corp-prod patch pvc opensearch-data-opensearch-0 --type merge --patch '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'
```

## Verification

After Argo CD sync, verify that the `opensearch-m16-retention-bootstrap` hook
succeeds, OpenSearch is writable, and OTel Collector no longer emits
`Failed ConsumeMetrics` or `data refused due to high memory usage` during a
continuous 1000-user run. Retain the Grafana p95/p99 and Collector log evidence
with the M16 results.
