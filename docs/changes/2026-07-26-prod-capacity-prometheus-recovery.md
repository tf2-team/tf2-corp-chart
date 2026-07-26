# Production Capacity and Prometheus Recovery

## Current State

On 2026-07-26, Lens showed `techx-corp-prod/frontend` at `30` desired replicas with only `15` available. The remaining `15` pods were Pending for more than two hours. The rest of the application tier was mostly Running; the broad symptom was not a namespace-wide CrashLoopBackOff.

The strongest crash/restart signal was in the observability tier: `prometheus` had restarted `9` times, was using about `5.7Gi` memory, and timed out on wide PromQL/series queries. The live Prometheus ConfigMap also had `scrape_interval: 1s`, `evaluation_interval: 1s`, and `scrape_timeout: 900ms`.

## Root Cause

The frontend HPA over-scaled during elevated load. It reported CPU above target and external `http_requests_per_second` above target, then raised the Deployment to `30` replicas. The production overlay kept the frontend RPS target at `80` per pod and CPU target at `65%`, which was too sensitive for spanmetrics-derived frontend traffic.

The extra frontend pods could not schedule because the workload placement contract was too strict for the available capacity:

- `nodeSelector.workload-class=spot-tolerant` limited eligible nodes to Karpenter workload nodes.
- Hostname topology spread used `DoNotSchedule`, so pods were blocked even when fragmented capacity existed.
- Karpenter events reported all available instance types exceeded `stateless-spot` and `stateless-on-demand` NodePool limits.
- Cluster Autoscaler events reported the managed node groups had reached max size.

Prometheus was a secondary pressure point. One-second scraping and high-cardinality metrics put pressure on TSDB memory, WAL replay, and query latency. This made observability less reliable while the cluster was already under scheduling pressure.

## Recovery Plan

1. Stop generating synthetic load by default. Keep the Locust master available, but scale production workers to `0` unless an operator intentionally starts a bounded load test.
2. Make frontend scale-out less aggressive. Raise the frontend CPU target to `80%`, raise RPS target to `180` per pod, cap production at `18` replicas, and slow the scale-up behavior.
3. Make frontend hostname spreading soft. Keep zone balancing soft and change hostname spread from `DoNotSchedule` to `ScheduleAnyway` so topology skew does not strand replicas while capacity is tight.
4. Reduce Prometheus production ingestion pressure. Set production scrape/evaluation interval to `30s`, timeout to `10s`, and retention to `24h`.
5. Follow up in `techx-corp-infra` if frontend still needs more than 18 replicas: increase Karpenter NodePool CPU/memory limits, then review instance category/zone constraints. This chart change intentionally does not mutate Terraform-owned NodePools.

## Verification

After GitOps reconciliation:

```bash
kubectl -n techx-corp-prod get hpa frontend
kubectl -n techx-corp-prod get deploy frontend
kubectl -n techx-corp-prod get pods -l opentelemetry.io/name=frontend -o wide
kubectl -n techx-corp-prod get configmap prometheus -o yaml | grep -E "scrape_interval|evaluation_interval|scrape_timeout"
kubectl -n techx-corp-prod top pod -l app.kubernetes.io/name=prometheus --containers
```

Expected result: frontend Pending pods fall toward zero after HPA converges, Prometheus query latency improves, and production only reintroduces load-generator workers during explicit test windows.
