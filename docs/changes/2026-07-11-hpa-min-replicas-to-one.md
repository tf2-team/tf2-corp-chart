# Change: Set All HPA minReplicas to 1

## Summary

Lowered Horizontal Pod Autoscaler floors for every first-party HPA service to `minReplicas: 1` in base `values.yaml`, and removed redundant per-service min overrides from the dev overlay so all environments share a single cost-oriented floor.

## Context

HPA services previously used `minReplicas: 2` on base/prod for demo HA (`frontend`, `checkout`, `cart`, `product-catalog`, `frontend-proxy`), with dev overlay only lowering cart, product-catalog, and frontend-proxy to 1. Operators want a uniform idle floor of one replica across all HPAs to reduce baseline pod (and node) cost while retaining the same max and scale behavior under load.

* Why now: cost reduction at idle without removing scale-out capacity.
* Constraint: first-party PDBs are gated on `minReplicas >= 2`; with min 1, those PDBs are no longer rendered.

## Before

* Base HPA mins: **2** for frontend, checkout, cart, product-catalog, frontend-proxy.
* Dev overlay forced min **1** for cart, product-catalog, frontend-proxy only; frontend/checkout stayed at 2.
* First-party PDBs rendered for all five services on base (min ≥ 2).

## After

* Base HPA mins: **1** for frontend, checkout, cart, product-catalog, frontend-proxy.
* Max unchanged: 6 for most; frontend-proxy max remains **3**.
* Metrics/behavior unchanged (CPU 70%, memory 90%, shared scaleUp/scaleDown policies).
* Dev overlay no longer overrides HPA minReplicas (inherits base).
* No first-party PDBs for these HPAs while min remains 1.

## Technical Design Decisions

* **Uniform min 1 in base** — avoids dual base/dev floors and matches the cost goal for all envs unless an overlay raises min later.
* **Leave max and behavior alone** — scale-out under load and 300s scale-down stabilization stay as-is.
* **Keep PDB gate as-is** — do not invent PDBs at min 1 (PDB with minAvailable 1 on a single-replica Deployment is ineffective / noisy). Raise `minReplicas` again if HA + PDB is required.
* **No template code change** — values-only.

## Implementation Details

1. Set `components.*.autoscaling.minReplicas: 1` for cart, checkout, frontend, frontend-proxy, product-catalog in `values.yaml`.
2. Removed cart / product-catalog / frontend-proxy HPA min overrides from `values-dev.yaml` (kept frontend-proxy public ALB settings).
3. Updated `docs/DEPLOYMENT.md` HPA inventory and verify expectations.
4. Updated `docs/operations/workload-placement.md` HPA table and PDB note.
5. Recorded this change document.

## Files Changed

**Configuration:**

* `values.yaml` — all five HPA services `minReplicas: 1`.
* `values-dev.yaml` — removed redundant minReplicas overrides.

**Documentation:**

* `docs/DEPLOYMENT.md` — inventory mins and verify text.
* `docs/operations/workload-placement.md` — HPA vs placement table.
* `docs/changes/2026-07-11-hpa-min-replicas-to-one.md` — this change record.

## Dependencies and Cross-Repository Impact

None. No infra change required. Related prior HPA work: `docs/changes/2026-07-11-improve-microservice-hpa.md`, `docs/changes/2026-07-11-hpa-memory-safety-valve.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Idle floor is one pod per HPA service; HA at rest is not guaranteed until HPA scales out |
| **Infrastructure** | Lower baseline CPU/memory requests; may allow fewer nodes under light load |
| **Deployment** | Helm/Argo sync updates HPA `minReplicas`; existing PDBs for these services are removed when min &lt; 2 |
| **Performance** | Cold path under sudden traffic may start from one replica (scale-up still fast: stabilization 0s) |
| **Security** | No change |
| **Reliability** | Reduced redundancy at idle; single-pod window until scale-out |
| **Cost** | Lower idle cost (primary goal) |
| **Backward compatibility** | Fully compatible; raise minReplicas to restore previous HA floor |
| **Observability** | HPA `MINPODS` column shows 1 |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (dev) | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass (icon INFO only) |
| Template HPA mins | `helm template` inspect HPA minReplicas | ✅ All five HPAs `minReplicas: 1`; no first-party PDB for those services |

### Manual Verification

* After sync: `kubectl -n <ns> get hpa` — all first-party HPAs show `MINPODS=1`.
* Confirm first-party PDBs for frontend/checkout/cart/catalog/proxy are gone (or not recreated) while min stays 1.

### Remaining Verification (Post-Merge)

* Operator: Argo/Helm sync to dev; optional prod when ready.
* Watch scale-out still works under load-generator traffic.

## Migration or Deployment Notes

1. Sync/upgrade the app chart (Argo auto-sync or Helm).
2. Expect HPA to allow scale-in toward 1 after stabilization (300s) if load is low.
3. To restore prior HA floor, set `minReplicas: 2` on selected services (PDBs return automatically when min ≥ 2).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Single-replica outage at idle for frontend/checkout | Medium | Medium | Raise minReplicas to 2 for HA services; scale-up policy remains aggressive |
| Loss of first-party PDBs | High (by design) | Low–Medium | Raise minReplicas ≥ 2 or add separate PDB policy |

**Rollback procedure:**

1. Set HPA `minReplicas` back to 2 for desired services in `values.yaml` (and re-add dev overrides if needed), or
2. `helm rollback` / Argo previous revision.
