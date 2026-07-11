# Change: OpenSearch CPU headroom and longer startup probe

## Summary

OpenSearch became Ready only after ~4 minutes on a 200m CPU limit, repeatedly emitting `Startup probe failed: dial tcp …:9200: connect: connection refused` during bootstrap. CPU is raised to 500m and the startup probe window is extended so cold start is faster and less likely to hit the failure threshold under load.

## Context

* Live cluster (`techx-corp-dev/opensearch-0`) with image `…/opensearch:sha-0a1ac72` and the previous `startupProbe` (period 10s, failureThreshold 30).
* Container stayed Running; logs advanced slowly with CPU pegged at **200m** (`kubectl top`).
* HTTP bind timeline on that run: process start `15:40:05` → `publish_address …:9200` / `started` at `15:44:21` (**~4m16s**).
* Earlier cycles without an adequate startup window were killed by liveness mid-bootstrap.
* Probe failures during the first minutes are expected while the JVM loads modules/plugins; they are not a crash by themselves.

## Before

* `resources.requests/limits.cpu: 200m` (Guaranteed with memory 1100Mi).
* `startupProbe`: TCP 9200, no `initialDelaySeconds`, `periodSeconds: 10`, `failureThreshold: 30` (~5 minutes from first probe).
* Cold start often consumed almost the entire startup budget on throttled CPU.

## After

* `resources.requests/limits.cpu: 500m` (still Guaranteed QoS with memory 1100Mi).
* `startupProbe.initialDelaySeconds: 30` (fewer noisy events in the first half-minute).
* `startupProbe.failureThreshold: 36` (~6.5 minutes total allowance: 30s + 36×10s).
* Inline comments document observed cold-start behavior and that early Unhealthy events are expected.

## Technical Design Decisions

* Prefer more CPU over only lengthening the probe: a longer window alone still leaves a multi-minute NotReady period and wastes throttled CPU.
* Keep heap at `-Xms400m -Xmx400m` and memory at 1100Mi; the bottleneck observed was CPU, not OOM.
* Keep Guaranteed QoS (`request == limit`) for the stateful search node.
* Alternatives rejected: disabling probes (hides real hangs); adding `IPC_LOCK` / memlock (already disabled for K8s); raising heap without CPU (would not fix plugin-load throttle).

## Implementation Details

1. Increased `components.opensearch.resources` CPU request and limit from `200m` to `500m`.
2. Set `startupProbe.initialDelaySeconds: 30` and `failureThreshold: 36`.
3. Updated comments in `values.yaml` with observed timings and operator guidance.

## Files Changed

**Configuration:**

* `values.yaml` — OpenSearch CPU 500m; longer/delayed `startupProbe`; explanatory comments.

**Documentation:**

* `docs/changes/2026-07-10-opensearch-cpu-startup-margin.md` — This change record.

## Dependencies and Cross-Repository Impact

None for code. After deploy, scheduling needs **+300m CPU** vs prior request; on tight nodes Karpenter / the node group must place the pod (same class of constraint already noted for OpenSearch memory in infra cost docs).

Related prior chart change: `docs/changes/2026-07-10-opensearch-startup-probe-memory-lock.md` (introduced `startupProbe` and `bootstrap.memory_lock=false`).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Faster cold start to `:9200`; fewer restart loops under slow bootstrap |
| **Infrastructure** | +300m CPU request/limit for the OpenSearch pod |
| **Deployment** | Helm upgrade / Argo CD sync of chart values |
| **Performance** | Lower CPU throttle during JVM/plugin load; shorter time to Ready |
| **Security** | No change (security plugin remains disabled for demo) |
| **Reliability** | Larger margin before startupProbe kills the container |
| **Cost** | Small increase in reserved CPU for one pod |
| **Backward compatibility** | Fully compatible values-only change |
| **Observability** | Logs / OTEL sink available sooner after pod schedule |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values review | Inspect `components.opensearch` resources and probes | ✅ Applied in repo |

### Manual Verification (cluster, pre-change baseline)

* `kubectl top pod opensearch-0 -n techx-corp-dev` — CPU held at 200m during bootstrap; memory ~500–650Mi.
* Logs: node started and bound `10.1.10.252:9200` after ~4m16s; pod reached `1/1 Ready` before the 5m failureThreshold on that run.
* Events: repeated `Startup probe failed: … connection refused` until bind, then Ready.

### Remaining Verification (Post-Merge)

1. Sync chart; wait for StatefulSet rollout (or `kubectl delete pod opensearch-0 -n techx-corp-dev` after sync).
2. `kubectl get pod opensearch-0 -n techx-corp-dev -w` until `1/1 Ready`.
3. Confirm cold start is typically well under ~3 minutes with 500m CPU (`kubectl logs` for `publish_address` / `started`).
4. Optional: `kubectl exec -n techx-corp-dev opensearch-0 -- curl -s http://127.0.0.1:9200/_cluster/health`.

## Migration or Deployment Notes

1. Deploy the chart revision that includes this `values.yaml` change.
2. Ensure the target node has free **500m CPU** and **1100Mi** memory for Guaranteed placement.
3. Early Unhealthy startup events for the first minutes after (re)start can still appear and are normal until `:9200` listens.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Pod Pending for Insufficient cpu after request increase | Medium on small clusters | Medium | Scale node group / Karpenter; temporarily lower CPU if needed |
| Cold start still > ~6.5 minutes under extreme contention | Low | Medium | Raise `failureThreshold` further or CPU limit |

**Rollback procedure:**

Revert `components.opensearch` `resources.cpu` and `startupProbe` fields in `values.yaml` to the previous values and redeploy the chart revision.
