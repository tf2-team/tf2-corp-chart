# Change: Raise otel-collector Agent Memory After OTLP Refuse

## Summary

Increase `opentelemetry-collector` DaemonSet resources from Guaranteed 20m/128Mi to Burstable 50m/200Mi request and 400m/512Mi limit so the collector `memory_limiter` soft ceiling stays above live working set, stopping OTLP `data refused due to high memory usage` that blocked currency (and other Simple* exporters) on the request path and inflated `POST /api/checkout` latency.

## Context

Post-change recheck of checkout latency (after currency CPU burst + minReplicas 3) showed Convert tails still multi-second with **zero CFS throttle**. Deep-dive found:

* Currency uses **SimpleSpanProcessor** and **SimpleLogRecordProcessor** (sync OTLP on every Convert / log).
* Currency pod logs: `Export() failed: data refused due to high memory usage` / gRPC `UNAVAILABLE`.
* Prometheus: `otelcol_receiver_refused_spans_total` ≈ 19/s.
* Agents at **~94–105 Mi** with **128 Mi** Guaranteed limit; `memory_limiter` `limit_percentage: 80` → soft limit ≈ **102 Mi**.
* Jaeger: same PlaceOrder had Convert pairs from ~2 ms to ~3 s (USD→USD); client−server gap ~500 ms on the worst pair (sync `span->End()` export).

Option 1 (batch processors in currency code) remains a follow-up. This change is the **ops/GitOps memory headroom** fix (option 2).

## Before

`values.yaml` `opentelemetry-collector.resources`:

| | CPU | Memory |
|---|---|---|
| requests | 20m | 128Mi |
| limits | 20m | 128Mi (Guaranteed) |

`memory_limiter`: `limit_percentage: 80`, `spike_limit_percentage: 25` → soft refuse near ~102 Mi while RSS already ~100 Mi.

## After

`values.yaml` `opentelemetry-collector.resources`:

| | CPU | Memory |
|---|---|---|
| requests | 50m | 200Mi |
| limits | 400m | 512Mi (Burstable) |

Soft limit ≈ 80% × 512 Mi ≈ **410 Mi**, well above observed working set. CPU limit restored so collector is not stuck at 20m Guaranteed under export load.

`memory_limiter` percentages unchanged.

## Technical Design Decisions

* **Raise cgroup limit first** — limiter keys off limit, not request; 128 Mi limit was the refuse trigger.
* **Burstable, not Guaranteed equal** — request 200 Mi for schedulability signal; limit 512 Mi for burst/queue headroom (aligned with 2026-07-11 probe-storm direction: 128/384, slightly higher limit after refuse evidence).
* **CPU 50m/400m** — Guaranteed 20m/20m was tight for concurrent OTLP + processors; match prior healthy agent profile.
* **No currency image change in this PR** — code still uses Simple* processors; this reduces export failure/block time. Batch processors remain recommended follow-up.
* **GitOps only** — Argo CD rolls DaemonSet; no live `kubectl set resources`.

## Implementation Details

1. Update `opentelemetry-collector.resources` and comments in base `values.yaml`.
2. Leave `values-prod.yaml` / `values-dev.yaml` without resource overrides (inherit base).
3. Argo CD DaemonSet rolling update per node after push.

## Files Changed

**Configuration:**

* `values.yaml` — otel-collector agent resources 20m/128Mi Guaranteed → 50m/200Mi request, 400m/512Mi limit.

**Documentation:**

* `docs/changes/2026-07-24-otel-collector-memory-otlp-refuse.md` — This change record.

## Dependencies and Cross-Repository Impact

None required for this change. Optional follow-up in `techx-corp-platform`: switch currency to `BatchSpanProcessor` / `BatchLogRecordProcessor` so request latency cannot couple to OTLP even under collector pressure.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Same OTLP API; fewer refused exports → shorter currency Convert when Simple* processors wait on collector |
| **Infrastructure** | Higher per-node DaemonSet memory request (~200 Mi) and limit (512 Mi); CPU request 50m |
| **Deployment** | Argo CD rolls `otel-collector` DaemonSet |
| **Performance** | Expected drop in Convert/checkout tail latency correlated with refuse rate |
| **Security** | No change |
| **Reliability** | Fewer OTLP refuse storms; less risk of probe/export feedback under load |
| **Cost** | Modest: ~200 Mi request × node count (was 128 Mi) |
| **Backward compatibility** | Fully compatible |
| **Observability** | More headroom to accept spans/logs/metrics; watch `otelcol_receiver_refused_spans_total` |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-prod.yaml` | Run after edit |
| Values review | Diff resources block | Applied |

### Manual Verification

* Pre-change: currency logs OTLP refuse; refuse rate ~19/s; Convert p99 multi-second.
* Post-sync (operator): agent resources and refuse rate; Jaeger Convert tails.

### Remaining Verification (Post-Merge)

1. Argo CD Application Healthy/Synced; DaemonSet pods Running with new limits.
2. `kubectl -n techx-corp-prod get pods -l app.kubernetes.io/name=opentelemetry-collector -o jsonpath` (or name `otel-collector-agent`) resources.
3. Prometheus: `sum(rate(otelcol_receiver_refused_spans_total[5m]))` near 0.
4. Currency logs: no sustained `data refused due to high memory usage`.
5. Jaeger/Prometheus: `currency` Convert and `frontend` `POST /api/checkout` p95/p99.

## Migration or Deployment Notes

1. Commit/push `techx-corp-chart` only.
2. Wait for Argo CD to roll DaemonSet (node-by-node).
3. Expect brief telemetry blip during agent restart; apps keep running.
4. If a node cannot schedule 200 Mi request, free node memory or temporarily lower request (keep 512 Mi limit).

```cmd
cd /d techx-corp-chart
helm lint . -f values.yaml -f values-prod.yaml
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Pod Pending on memory-tight nodes | Low–Medium | Medium | Lower request to 128Mi keep limit 512Mi; free node mem |
| OOM at 512Mi under extreme load | Low | Medium | Tune batch/queue; follow-up batch processors in apps |
| Checkout latency still high | Medium | Medium | Option 1: currency Batch processors (platform) |

**Rollback procedure:**

1. Revert this commit (restore 20m/128Mi Guaranteed).
2. Push; Argo CD reconciles previous DaemonSet resources.

<!-- Change trail: @hungxqt - 2026-07-24 - Document otel-collector memory raise for OTLP refuse / checkout latency. -->
