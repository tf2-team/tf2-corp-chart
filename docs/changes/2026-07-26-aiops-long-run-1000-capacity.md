# AIOps long-run 1,000-user collection profile

## Purpose

AIOps needs a stable multi-hour load window at approximately 1,000 virtual
users to collect logs and metrics for training. This profile is intentionally
separate from normal production capacity: it raises the HPA ceiling and warm
floor for the synchronous storefront path, then increases the observability
components that previously failed first under long load.

The profile is active only while
`values-aiops-long-run-1000.yaml` remains in the production Argo CD
Application. It is not evidence for Mandate 16 and must be removed after the
approved AIOps collection window.

## Capacity changes

| Area | Long-run setting |
| --- | --- |
| Frontend | 6–40 replicas |
| Frontend proxy | 4–20 replicas |
| Checkout | 4–30 replicas |
| Cart / product-catalog | 4–24 replicas |
| Currency | 4–20 replicas |
| Recommendation / quote / shipping | 4–20 replicas |
| Product reviews | 2–12 replicas; CPU raised to 250m request / 1 core limit |
| Payment / email | 4 / 3 fixed replicas |

The chart continues to use HPA; these are ceilings and warm floors, not a
permanent allocation. Stateless pods are scheduled by Karpenter. Prometheus,
Jaeger, OpenSearch, and frontend-proxy remain on the critical managed node
groups, which Cluster Autoscaler may grow up to their configured limits.

## Observability changes

- Prometheus scrapes and evaluates every second, keeps 24 hours of data, and
  receives 1 CPU / 6GiB plus a 48Gi PVC.
- The OTel Collector flushes spanmetrics and collects Kafka metrics every
  second. Each agent receives 1–2GiB memory so its soft limiter cannot erase
  metrics/traces while logs are exporting.
- Jaeger remains memory-backed but is bounded at 50,000 recent traces with a
  6GiB limit. It preserves a useful recent investigation window instead of
  growing until OOMKilled.
- OpenSearch receives 2 CPU / 4GiB with a 2GiB JVM heap. The AIOps ISM policy
  keeps `otel-logs-*` for two days and removes older daily indices.
- Logs have a bounded 1,024-item, 60-second exporter backlog. A failed log
  store can drop logs after that bounded period, but cannot consume all
  Collector memory and create gaps in metrics or traces.

## Metrics supplied to AIOps

The profile retains the raw RED metrics listed in the CDO catalog and makes
the collector-produced metrics one-second resolution. The live Prometheus
inventory already contains the resource and health families needed by AIOps:

- Request/error/latency: `http_server_request_duration_seconds_*`,
  `rpc_server_duration_milliseconds_*`, and
  `traces_span_metrics_{calls_total,duration_milliseconds_bucket}`.
- CPU and memory: `container_cpu_usage_seconds_total` and
  `container_memory_working_set_bytes`.
- Disk and network I/O: `container_fs_{reads,writes}_bytes_total` and
  `container_network_{receive,transmit}_bytes_total`.
- Ready state and OOM signal: `kube_pod_status_ready` and
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`.
- Dependency signals: `otelcol_exporter_queue_{size,capacity}`,
  `kafka_consumer_records_lag`, `db_client_connection_count`, and
  `redis_memory_used_bytes`. The profile adds a TLS Redis receiver pointed at
  the managed ElastiCache primary because in-cluster pod discovery cannot see
  that external endpoint.

The AIOps runtime configuration is owned outside this chart. This profile
supplies the Prometheus time series; AIOps should add its own detector/query
instances for OOM, queue saturation, DB pool utilisation, Kafka lag and
resource signals as required by its training pipeline.

## Required operator steps

1. Merge the chart change and wait for the Argo CD Application to be
   `Synced` and `Healthy`. Confirm the retention bootstrap Job succeeds.
2. Expand the existing OpenSearch PVC from 30Gi to 80Gi. This is deliberately
   not expressed in `volumeClaimTemplates`, because StatefulSet template
   storage is immutable after creation:

   ```powershell
   wsl kubectl -n techx-corp-prod patch pvc opensearch-data-opensearch-0 --type merge --patch '{"spec":{"resources":{"requests":{"storage":"80Gi"}}}}'
   ```

3. Before starting Locust, verify there are no Pending pods and that the
   Collector, Prometheus, Jaeger, OpenSearch, metrics-server, and all HPA
   workloads are Ready. Let the warm floor settle before ramping to 1,000 users.
4. During the run, watch OpenSearch disk, Jaeger memory, Collector queue
   saturation, Prometheus readiness and OOMKilled counters. Stop the load and
   investigate before any component reaches its limit; do not keep a failed
   collection window as training data.

## Rollback and cost boundary

After collection, remove `values-aiops-long-run-1000.yaml` from the production
Argo CD Application and let Argo prune the retention Job/CronJob/NetworkPolicy.
Then remove the `aiops-otel-logs-retention` ISM policy after it is detached
from `otel-logs-*`. The retained OpenSearch, Prometheus, and EBS PVC
expansions cannot be shrunk in place; reducing them requires a planned volume
migration. The temporary node, storage and observability capacity increases
must be reviewed against the $300/week budget before each collection window.
