# Change: Fix Prometheus Memory Cap and Probe Restart Storm

## Summary

Raised Prometheus server CPU/memory headroom, enabled a long `startupProbe`, relaxed readiness probe timeouts, and shortened emptyDir retention so the server stops thrashing at its 400Mi cgroup limit and being killed by liveness probes during WAL replay and OTLP ingest.

## Context

Pod `prometheus-7bb867cf7-4rwcq` in `techx-corp-dev` was `0/1 Ready` with repeated:

* Readiness: `Get "http://…:9090/-/ready": context deadline exceeded` (timeout 4s)
* Liveness: same on `/-/healthy` → container kill/restart loop

Live evidence at incident time:

* Working set **~396–398Mi** vs limit **400Mi**
* Node `ip-10-1-11-157` (`t4g.medium`, critical): packed with OpenSearch, Kafka, PostgreSQL, flagd, frontend-proxy
* Node memory ~89%; memory limits overcommitted (~102%)
* WAL replay on restart **~28s**; readiness timeout was only **4s** with **no startupProbe**
* OTLP receiver enabled (`web.enable-otlp-receiver`) — continuous remote-write load from collectors

## Before

* `resources.requests`: cpu 100m / memory 256Mi  
* `resources.limits`: cpu 300m / memory **400Mi**  
* `retention: 7d` on emptyDir  
* Chart default probes: readiness timeout **4s**, no startupProbe  
* Hard placement on Critical MNG unchanged

## After

* `resources.requests`: cpu 150m / memory **400Mi**  
* `resources.limits`: cpu 750m / memory **768Mi**  
* `retention: 2d` (emptyDir — bound WAL growth between restarts)  
* `startupProbe.enabled: true` (period 10s, failureThreshold 30 ≈ 5 min budget, timeout 10s)  
* Readiness timeout **10s**, period **10s**; liveness period **20s**  
* Critical `nodeSelector` unchanged

## Technical Design Decisions

* **Raise the memory limit first** — root cause was cgroup pressure (RSS ≈ limit), not a broken health endpoint. Probe-only tuning would mask OOM thrash.
* **startupProbe** — WAL replay already exceeds the old readiness timeout window; without startup, liveness restarts during legitimate boot and grows WAL further.
* **Shorten retention on emptyDir** — no PVC today; 7d retention increases restart cost without durable benefit across reschedule.
* **Keep Prometheus on Critical MNG** — matches observability control-plane contract; capacity follow-up (larger system nodes or PVC) is separate.
* **Do not move to Karpenter Spot** in this fix — would violate critical placement policy.

## Implementation Details

1. Updated `prometheus.server.resources` in base `values.yaml`.
2. Enabled and tuned `prometheus.server.startupProbe` and readiness/liveness timing keys supported by chart `prometheus-29.6.0`.
3. Set `retention: 2d` for emptyDir TSDB.
4. Recorded this change document.

## Files Changed

**Configuration:**

* `values.yaml` — Prometheus server resources, probes, retention.

**Documentation:**

* `docs/changes/2026-07-11-fix-prometheus-memory-probe-storm.md` — this change record.

## Dependencies and Cross-Repository Impact

* Critical MNG (`t4g.medium` × 2) remains tight after this bump. If scheduling fails with `Insufficient memory`, operators must raise system MNG size/instance type in `techx-corp-infra` (separate change).
* Related placement docs: `docs/operations/workload-placement.md`, infra `docs/workload-placement.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Prometheus should become Ready and stop liveness kill loops under normal OTLP + scrape load |
| **Infrastructure** | Slightly higher memory request on Critical MNG; may surface capacity pressure if both AZs full |
| **Deployment** | Helm/Argo sync rolls Prometheus Deployment |
| **Performance** | Higher CPU/memory ceiling; less GC/probe stall under OTLP |
| **Reliability** | Removes restart storm; metrics continuity improves while pod is stable |
| **Cost** | Marginal (same nodes unless MNG must be enlarged later) |
| **Observability** | Restores scrape/OTLP ingest path when pod Ready |
| **Backward compatibility** | Fully compatible; retention window shortened for emptyDir only |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass |
| Helm template | resources 150m/400Mi → 750m/768Mi; startupProbe; readiness timeout 10; retention 2d | ✅ Pass |

### Manual Verification

* Pre-fix: RSS ~398Mi / 400Mi limit; readiness timeout 4s; 5+ restarts; WAL replay ~28s.
* Live emergency patch applied on `techx-corp-dev` (same resource/probe/retention settings); pod `prometheus-694dfd45d8-prqm5` reached **1/1 Ready**, restarts 0.
* **Git remains source of truth** — commit/sync this chart change so Argo CD does not revert the live patch.

### Remaining Verification (Post-Merge)

* Confirm Argo sync applied new resources/probes.
* If Pending on schedule: scale Critical MNG or enlarge instance type (infra).
* Consider PVC + longer retention as a later reliability improvement.

## Migration or Deployment Notes

1. Sync chart to `techx-corp-dev` (Argo CD or Helm upgrade).
2. Watch pod: may restart once to pick up new limits.
3. Optional immediate relief without full chart sync (emergency only):  
   `kubectl -n techx-corp-dev set resources deploy/prometheus --limits=cpu=750m,memory=768Mi --requests=cpu=150m,memory=400Mi`  
   then re-apply chart values so Git remains source of truth.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Insufficient memory to schedule new request | Medium | Medium | Temporary lower request or enlarge system MNG |
| Still OOM at 768Mi under heavy OTLP | Low | Medium | Cap OTel export rate / add PVC / larger node |
| Shorter retention loses history | Low | Low | Accept for emptyDir; restore 7d only with PVC |

**Rollback procedure:**

1. Revert `values.yaml` Prometheus server block to prior resources/probes/retention.
2. Re-sync chart.
