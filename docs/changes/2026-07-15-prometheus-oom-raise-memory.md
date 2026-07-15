# Change: Raise Prometheus memory after OOMKilled CrashLoop

## Summary

Raised Prometheus server memory (and slightly CPU limit / startup budget) so the pod can complete PVC WAL replay and accept OTLP/exemplar ingest without hitting the cgroup limit and entering `OOMKilled` / CrashLoopBackOff.

## Context

Live prod pod `prometheus-745f48649f-2mzzn` (`techx-corp-prod`) was `CrashLoopBackOff` with:

* Last state: **`OOMKilled`**, exit **137**
* Limits: cpu 750m / memory **2Gi**; requests: 100m / **1280Mi**
* PVC `prometheus` 8Gi, retention 2d, flags `enable-feature=exemplar-storage` and `web.enable-otlp-receiver`
* Logs: WAL segments loaded through max segment ~63; **total_replay_duration ≈ 50s**, then kill
* Critical node `t4g.large` had enough free request budget to allow a higher limit with a moderate request raise

The prior raise (through 2Gi) covered emptyDir / smaller head cases; durable PVC + continuous OTLP under load grew the head/WAL past 2Gi on every restart.

* Related: `docs/changes/2026-07-11-fix-prometheus-memory-probe-storm.md`

## Before

```yaml
resources:
  requests:
    cpu: 100m
    memory: 1280Mi
  limits:
    cpu: 750m
    memory: 2Gi
startupProbe:
  failureThreshold: 30  # ~5 min
```

## After

```yaml
resources:
  requests:
    cpu: 100m
    memory: 1536Mi
  limits:
    cpu: "1"
    memory: 3Gi
startupProbe:
  failureThreshold: 36  # ~6 min for longer WAL replay
```

Retention (2d), PVC (8Gi), OTLP, and exemplar flags are unchanged in this slice.

## Technical Design Decisions

* **Raise limit to 3Gi first** — confirmed root cause is cgroup OOM during/after WAL replay, not probes.
* **Request 1536Mi (not 3Gi)** — keeps Critical MNG packing feasible on dual `t4g.large`; avoid starving Kafka/Postgres/proxies on the same floor.
* **CPU limit 1** — WAL replay is CPU-sensitive; 750m prolonged the memory spike window.
* **startupProbe 36 × 10s** — replay already ~50s; leave margin if head grows further before Ready.
* **Deferred:** shorter retention, disable exemplars, PVC wipe — use if 3Gi still OOMs or for emergency recovery only.

## Implementation Details

1. Updated `prometheus.server.resources` and `startupProbe.failureThreshold` in base `values.yaml`.
2. Recorded this change document.

## Files Changed

**Configuration:**

* `values.yaml` — Prometheus server request/limit and startupProbe failureThreshold.

**Documentation:**

* `docs/changes/2026-07-15-prometheus-oom-raise-memory.md` — This change record.

## Dependencies and Cross-Repository Impact

* Critical MNG remains `t4g.large` × 2 (infra). If the new request fails to schedule (`Insufficient memory`), enlarge system MNG or rebalance co-located critical pods — separate infra change.
* No platform image change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Prometheus should complete WAL replay and stay Ready under normal OTLP + scrape load |
| **Infrastructure** | +256Mi memory request on Critical MNG; higher peak limit when used |
| **Deployment** | Argo/Helm rolls Prometheus Deployment with new resources |
| **Performance** | Faster replay possible with CPU limit 1; more headroom for head block |
| **Reliability** | Breaks OOM CrashLoop when 3Gi is sufficient for current WAL |
| **Cost** | Marginal on existing nodes unless MNG must grow later |
| **Observability** | Restores scrape/OTLP/HPA external metrics path when Ready |
| **Backward compatibility** | Fully compatible resource raise |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values | Inspect `prometheus.server.resources` | ✅ 1536Mi / 3Gi, cpu 100m / 1 |
| startupProbe | `failureThreshold: 36` | ✅ |

### Manual Verification

After GitOps sync:

```cmd
kubectl -n techx-corp-prod get pod -l app.kubernetes.io/name=prometheus
kubectl -n techx-corp-prod describe pod -l app.kubernetes.io/name=prometheus
kubectl -n techx-corp-prod top pod -l app.kubernetes.io/name=prometheus
```

Expect: no `OOMKilled`, Ready **1/1**, working set under 3Gi with headroom.

### Remaining Verification (Post-Merge)

* Operator: Argo CD sync chart app.
* If still OOM: consider retention shorten, exemplar disable, or one-time PVC clear (data loss) after confirming limit is applied.
* Watch Critical node memory after roll.

## Migration or Deployment Notes

1. Merge/sync **techx-corp-chart** only.
2. No image rebuild.
3. Deployment rolls automatically; PVC data is retained.

```cmd
REM After GitOps sync
kubectl -n techx-corp-prod get deploy prometheus -o jsonpath="{.spec.template.spec.containers[0].resources}"
kubectl -n techx-corp-prod get pod -l app.kubernetes.io/name=prometheus
```

**Emergency if CrashLoop continues after 3Gi applied:** scale deploy to 0, clear or recreate PVC (loses local TSDB history), scale to 1 — only with operator approval.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Still OOM at 3Gi under peak cardinality | Low–Medium | High | Raise to 4Gi or reduce retention/OTLP cardinality; optional PVC reset |
| Insufficient memory to schedule 1536Mi request | Low | Medium | Temporarily lower request or free Critical capacity |
| Higher co-location pressure on critical node | Medium | Low | Monitor node; move non-essential critical tenants if needed |

**Rollback procedure:**

Restore previous resources in `values.yaml`:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 1280Mi
  limits:
    cpu: 750m
    memory: 2Gi
startupProbe:
  failureThreshold: 30
```

Re-sync the chart Application.

<!-- Change trail: @hungxqt - 2026-07-15 - Raise Prometheus memory after OOMKilled CrashLoop. -->
