# Change: Add HPA for load-generator

## Summary

Enabled Horizontal Pod Autoscaler for `load-generator` using the same dual-metric Option B policy as other first-party HPA services (CPU 70% primary, memory 90% safety valve, shared scale behavior), so Locust pods can scale out under CPU/memory pressure when operators ramp synthetic traffic.

## Context

Hot-path services (`frontend`, `checkout`, `cart`, `product-catalog`, `frontend-proxy`) already had HPA. `load-generator` remained a fixed single Deployment while operators can raise Locust user counts from the UI (e.g. 200 users). The load-generator pod is constrained (requests 200m/500Mi, limits 300m/1000Mi) and is often the first bottleneck under heavy Locust swarms or browser traffic—not the backends alone.

* Related prior work: `docs/changes/2026-07-11-improve-microservice-hpa.md`, `docs/changes/2026-07-11-hpa-memory-safety-valve.md`, `docs/changes/2026-07-11-move-load-generator-to-karpenter.md`.
* Constraint: chart Locust is not configured as distributed master/worker; each replica with `LOCUST_AUTOSTART=true` independently runs `LOCUST_USERS`.

## Before

* `components.load-generator` had no `autoscaling` block.
* Deployment used fixed `default.replicas` (1).
* No HPA object named `load-generator`; no PDB for load-generator (min would be 1 anyway).

## After

* `load-generator` HPA enabled:
  * `minReplicas: 1`
  * `maxReplicas: 6`
  * `targetCPUUtilizationPercentage: 70`
  * `targetMemoryUtilizationPercentage: 90`
  * `behavior: *hpa-behavior-default` (same shared scale-up/down policies as cart and peers)
* Deployment omits static `replicas` when HPA is enabled (existing template behavior).
* No PDB for load-generator (PDB gate is `minReplicas >= 2`).

## Technical Design Decisions

* **Same metrics and behavior as other HPAs** — Option B dual metrics and shared `hpa-behavior-default` for operational consistency.
* **`minReplicas: 1` (not 2)** — Unlike frontend/checkout, load-generator is not user-facing HA. With `LOCUST_AUTOSTART`, each extra always-on replica multiplies baseline synthetic traffic (`LOCUST_USERS` per pod). min 2 would permanently double default load.
* **`maxReplicas: 6`** — Matches other Karpenter HPA services; scale-out provides headroom when a single Locust process hits CPU/mem limits under large UI-driven swarms.
* **No Locust distributed mode in this change** — True shared swarm across workers would need master/worker wiring and a stable Locust master Service. Independent replicas are acceptable for demo capacity relief and intentional load multiplication.
* **No dev overlay override** — Base already min 1; no cost change required in `values-dev.yaml`.

## Implementation Details

1. Added `components.load-generator.autoscaling` in `values.yaml` with dual metrics and shared behavior anchor.
2. Documented inventory in `docs/DEPLOYMENT.md` and placement matrix in `docs/operations/workload-placement.md`.
3. Template path unchanged: `templates/hpa.yaml` already renders any component with `autoscaling.enabled`.

## Files Changed

**Configuration:**

* `values.yaml` — `load-generator` autoscaling block (Option B + shared behavior).

**Documentation:**

* `docs/DEPLOYMENT.md` — HPA inventory row and describe command include `load-generator`.
* `docs/operations/workload-placement.md` — multi-replica HPA vs placement table.
* `docs/changes/2026-07-11-add-load-generator-hpa.md` — this change record.

## Dependencies and Cross-Repository Impact

None required. Depends on existing Metrics Server (`metrics.k8s.io`) and Karpenter spot-tolerant NodePools already used by load-generator.

* Related: prior HPA chart changes above; platform Locust image unchanged.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Under Locust CPU/mem pressure, additional load-generator pods may start; each with `LOCUST_AUTOSTART` adds another independent swarm of `LOCUST_USERS` |
| **Infrastructure** | Karpenter may provision extra spot-tolerant capacity for scaled load-generator pods (500Mi request each) |
| **Deployment** | Helm/Argo sync creates `HorizontalPodAutoscaler/load-generator`; Deployment replicas managed by HPA |
| **Performance** | Loadgen can scale beyond a single 300m CPU / 1Gi limit; backend traffic may increase when multiple pods autostart |
| **Security** | No change |
| **Reliability** | Reduces single-pod loadgen OOM/throttle under heavy UI swarms; scale-down stabilization 300s |
| **Cost** | Idle cost unchanged (min 1); scale-out temporary under pressure |
| **Backward compatibility** | Fully compatible; set `components.load-generator.autoscaling.enabled: false` to restore fixed replicas |
| **Observability** | New HPA visible in `kubectl get hpa` / metrics-server |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (dev) | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass (icon INFO only) |
| Helm lint (prod) | `helm lint . -f values.yaml -f values-prod.yaml` | ✅ Pass (icon INFO only) |
| Template HPA | `helm template` HPA `load-generator`: min 1 / max 6, CPU 70 / Mem 90, shared behavior; Deployment omits static `replicas` | ✅ Pass |

### Manual Verification

* After sync: `kubectl -n techx-corp get hpa load-generator`
* Confirm Deployment has no static high replicas and HPA controls scale.
* Optional stress: ramp Locust users in UI; watch HPA desired replicas and load-generator pod count.

### Remaining Verification (Post-Merge)

1. Argo/Helm sync in dev.
2. Confirm metrics-server reports CPU/memory for load-generator pods.
3. If scale-out multiplies traffic too aggressively, lower `maxReplicas`, disable `LOCUST_AUTOSTART` on secondary usage, or introduce Locust distributed mode in a follow-up.

## Migration or Deployment Notes

1. Sync chart (Argo CD or `helm upgrade`).
2. No image rebuild required.
3. Operators should know: scaling load-generator **multiplies** independent Locust swarms when `LOCUST_AUTOSTART=true`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Scale-out multiplies synthetic traffic (`LOCUST_USERS` × replicas) | Medium | Medium | Keep min 1; lower max; or set `LOCUST_AUTOSTART=false` and drive load from one controller |
| Karpenter cost under prolonged high Locust CPU | Low | Low | Scale-down stabilization 300s; disable HPA if needed |
| Locust UI Service load-balances across replicas (split UI/state) | Medium | Low | Prefer one interactive master; treat extra pods as workers-for-capacity only until distributed mode exists |

**Rollback procedure:**

Set `components.load-generator.autoscaling.enabled: false` (and optional `replicas: 1`) and re-sync, or revert this chart change.
