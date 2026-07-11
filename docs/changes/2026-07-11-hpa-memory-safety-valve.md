# Change: HPA Option B — Memory Safety Valve (Dual Metrics)

## Summary

Enabled dual-metric HPA on all five autoscaled services: CPU **70%** remains the primary scale signal; memory **90%** is added as a high-threshold safety valve. Right-sized `product-catalog` CPU/memory requests and `GOMEMLIMIT` so the memory metric does not thrash under normal Go RSS.

## Context

The prior HPA hardening change (`2026-07-11-improve-microservice-hpa`) used **CPU-only** targets to avoid the thrash of dual 80%/80% CPU+memory. Operators still want a soft response when pods approach memory request capacity (before hard OOM kills). Option B restores memory metrics at a **high** target so they rarely dominate HPA’s max-of-metrics calculation under idle or light load.

* Related: `docs/changes/2026-07-11-improve-microservice-hpa.md`
* Constraint: no template API change; memory metric path already existed.

## Before

* Five HPAs: CPU utilization **70%** only (no memory metric).
* `product-catalog`: requests 50m/64Mi, limits 200m/128Mi, `GOMEMLIMIT=100MiB`.
* Docs described CPU-only inventory.

## After

* Five HPAs: CPU **70%** + memory **90%** (Option B dual metrics).
* `product-catalog`: requests **100m/128Mi**, limits **300m/256Mi**, `GOMEMLIMIT=200MiB` (aligned with checkout for safe memory HPA).
* Docs document max-of-metrics behavior and “raise requests if idle mem high” guidance.

## Technical Design Decisions

* **90% memory, not 80%** — equal dual targets previously caused premature scale-out; safety valve must sit near request.
* **All five services** — single reviewable policy; Envoy (`frontend-proxy`) typically low RSS so memory rarely wins.
* **Right-size catalog first** — 90% of 64Mi would fire under normal Go RSS and defeat Option B.
* **No template change** — `techx-corp.hpa` already emits memory when `targetMemoryUtilizationPercentage` is set.
* **Limits / GOMEMLIMIT remain hard OOM path** — HPA memory is soft capacity only.

## Implementation Details

1. Set `targetMemoryUtilizationPercentage: 90` on cart, checkout, frontend, frontend-proxy, product-catalog.
2. Updated product-catalog resources and `GOMEMLIMIT` to match checkout-scale headroom.
3. Replaced “CPU-only” comments with Option B dual-metric wording.
4. Updated DEPLOYMENT HPA inventory and workload-placement HPA table.
5. Recorded this change document.

## Files Changed

**Configuration:**

* `values.yaml` — dual metrics on five services; product-catalog resource/`GOMEMLIMIT` right-size.

**Documentation:**

* `docs/DEPLOYMENT.md` — Option B policy + inventory.
* `docs/operations/workload-placement.md` — HPA metric note.
* `docs/changes/2026-07-11-hpa-memory-safety-valve.md` — this change record.

## Dependencies and Cross-Repository Impact

None. Related prior chart change: `docs/changes/2026-07-11-improve-microservice-hpa.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Extra replicas if average memory working set ≥ ~90% of request (in addition to CPU-driven scale) |
| **Infrastructure** | Slightly higher product-catalog request footprint; possible extra pods only under memory pressure |
| **Deployment** | Standard chart sync; no special flags |
| **Performance** | Protects against memory-bound saturation without changing primary CPU path |
| **Security** | No change |
| **Reliability** | Soft mitigation near memory request; reduces OOM risk under slow memory growth |
| **Cost** | Minimal if idle mem ≪ 90%; sticky replicas if requests understated |
| **Backward compatibility** | Fully compatible; remove memory target to revert to CPU-only |
| **Observability** | HPA TARGETS show both cpu and memory |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (dev) | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass (icon INFO only) |
| Helm lint (prod) | `helm lint . -f values.yaml -f values-prod.yaml` | ✅ Pass (icon INFO only) |
| Template metrics | `helm template` | ✅ 5 HPAs; each has `averageUtilization: 70` (cpu) and `90` (memory) |
| product-catalog resources | rendered Deployment | ✅ req 100m/128Mi, lim 300m/256Mi, GOMEMLIMIT=200MiB |

### Manual Verification

* Rendered product-catalog Deployment shows 128Mi request and `GOMEMLIMIT=200MiB`.
* Behavior scale-down stabilization 300s unchanged.

### Remaining Verification (Post-Merge)

* `kubectl top pods` / `describe hpa` — idle memory util well below 90% of request.
* Optional load-generator soak — confirm scale-out primarily tracks CPU.

## Migration or Deployment Notes

1. Sync/upgrade the app chart as usual.
2. After deploy, check idle memory utilization vs request; if any HPA service idles above ~70% of request, raise `requests.memory` before relying on the safety valve.
3. No infra change required for this chart update alone.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Understated requests → sticky high replicas | Medium | Medium | Catalog right-size; 90% target; raise requests if needed |
| Operators confuse dual TARGETS | Low | Low | DEPLOYMENT documents max-of-metrics |

**Rollback procedure:**

1. Remove `targetMemoryUtilizationPercentage` from the five services (CPU-only), or
2. `helm rollback` / Argo previous revision.
