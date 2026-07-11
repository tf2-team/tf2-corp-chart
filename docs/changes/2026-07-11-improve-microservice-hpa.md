# Change: Improve Microservice HPA Coverage and Hardening

## Summary

Hardened existing Horizontal Pod Autoscalers (CPU-only targets, shared scale behavior, checkout resource alignment), extended HPA to `cart`, `product-catalog`, and `frontend-proxy`, and added PodDisruptionBudgets for multi-replica HPA Deployments. Dev overlay lowers min replicas for the newly expanded services to control cost.

## Context

Only `frontend` and `checkout` had HPA, both using dual CPU+memory utilization at 80%. Memory-based scaling thrash is common for Go/.NET/Node, and checkout’s small requests plus `GOMEMLIMIT` made memory HPA especially noisy. Hot-path dependencies stayed at one replica while frontend/checkout could grow to six. The edge gateway (`frontend-proxy`) was a single replica on the Critical MNG. There was no HPA behavior block and no first-party PDB for multi-replica app Deployments.

* Plan: improve microservice HPA (session plan)
* Constraints: no placement redesign (proxy stays critical); no consumer/stateful HPA; no KEDA/custom metrics in this change.

## Before

* HPA only for `frontend` and `checkout` (min 2 / max 6, CPU 80% **and** memory 80%).
* No `spec.behavior` on HPAs.
* No first-party PDB for app Deployments.
* `cart`, `product-catalog`, `frontend-proxy` fixed at default replica count (1).
* Checkout: requests 50m/64Mi, limits 200m/128Mi, `GOMEMLIMIT=100MiB`.

## After

* **Five** HPAs (base/prod): `frontend`, `checkout`, `cart`, `product-catalog` (min 2 / max 6, CPU **70%** only), `frontend-proxy` (min 2 / max **3**, CPU 70% only).
* Shared HPA `behavior` (fast scale-up, 300s scale-down stabilization, percent-based policies).
* PDB `minAvailable: 1` when HPA enabled and `minReplicas >= 2`.
* Template fails if autoscaling is enabled without at least one utilization metric.
* Checkout requests/limits raised; `GOMEMLIMIT=200MiB`.
* Dev (`values-dev.yaml`): `cart`, `product-catalog`, `frontend-proxy` `minReplicas: 1`.

## Technical Design Decisions

* **CPU-only metrics** — HPA takes the max across metrics; memory utilization often stays high without load correlation. Memory target remains supported in template/schema for intentional use later.
* **Shared behavior via YAML anchor** — one default scale policy reused across services; overridable per component.
* **Conservative `frontend-proxy` max=3** — Critical MNG is a small floor without automatic scale-out by default; high max would only increase Pending risk.
* **cart + product-catalog first** — highest leverage under scaled frontend/checkout; both can use Karpenter. Second-wave services deferred until load baselines exist.
* **PDB only for multi-replica HPA** — avoids PDB noise on single-replica workloads; minAvailable 1 matches minReplicas 2.
* **Dev min=1 for expanded services** — keeps frontend/checkout HA for demos while reducing Critical/Karpenter floor cost in development.

## Implementation Details

1. Extended `techx-corp.hpa` with metric requirement `fail`, optional `behavior` passthrough.
2. Added `techx-corp.pdb` + `templates/pdb.yaml` loop gated on HPA + minReplicas ≥ 2.
3. Extended `values.schema.json` `Autoscaling` with optional `behavior` object.
4. Updated `values.yaml` autoscaling for five services; defined `&hpa-behavior-default` on `cart` (first HPA block in file) and aliased elsewhere.
5. Right-sized checkout resources and `GOMEMLIMIT`.
6. Dev overlay min overrides for cart / product-catalog / frontend-proxy.
7. Documented inventory and Critical capacity note in DEPLOYMENT and workload-placement ops docs.

## Files Changed

**Templates:**

* `templates/_objects.tpl` — HPA behavior + metric guard; new PDB helper.
* `templates/pdb.yaml` — PDB rendering for multi-replica HPA components.

**Configuration:**

* `values.yaml` — HPA coverage, CPU-only targets, behavior, checkout resources.
* `values-dev.yaml` — minReplicas 1 for cart, product-catalog, frontend-proxy.
* `values.schema.json` — `Autoscaling.behavior` property.

**Documentation:**

* `docs/DEPLOYMENT.md` — HPA inventory, PDB verify commands, Critical capacity note.
* `docs/operations/workload-placement.md` — multi-replica HPA vs placement.
* `docs/changes/2026-07-11-improve-microservice-hpa.md` — this change record.

## Dependencies and Cross-Repository Impact

None required for merge. Optional follow-up in `techx-corp-infra` if Critical MNG capacity is insufficient for `frontend-proxy` minReplicas 2 in an environment (raise MNG desired/max or free Critical workloads).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Hot-path services can scale out under CPU pressure; edge can run dual proxy pods when Critical capacity allows |
| **Infrastructure** | Higher baseline pod count (base/prod); Karpenter may add nodes for catalog/cart scale-out; Critical floor pressure for proxy |
| **Deployment** | Helm/Argo sync applies new HPA + PDB objects; no special install flags |
| **Performance** | Better headroom under load for scaled path; scale-down delayed ~5 minutes by design |
| **Security** | No change |
| **Reliability** | Multi-replica + PDB for HPA services; dual metric thrash reduced |
| **Cost** | Higher steady requests at min replicas (base/prod); mitigated in dev via min=1 on three services |
| **Backward compatibility** | Fully compatible; operators can disable per-service `autoscaling.enabled` |
| **Observability** | More HPA objects visible in `kubectl get hpa` / metrics-server path |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (dev) | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass (icon INFO only) |
| Helm lint (prod) | `helm lint . -f values.yaml -f values-prod.yaml` | ✅ Pass (icon INFO only) |
| Template inventory (base) | `helm template` + inventory script | ✅ 5 HPAs (CPU 70, scaleDown stab 300); 5 PDBs; no Deployment replicas |
| Template inventory (dev) | `helm template -f values-dev.yaml` | ✅ cart/catalog/proxy min=1; PDBs only frontend+checkout |
| Checkout resources | rendered Deployment | ✅ GOMEMLIMIT=200MiB; requests 100m/128Mi |

### Remaining Verification (Post-Merge)

* Cluster: Metrics Server Ready; HPA TARGETS not `<unknown>`; smoke test storefront.
* If `frontend-proxy` Pending at min=2: review Critical node allocation (operator / infra).

## Migration or Deployment Notes

1. Ensure Metrics Server is enabled (chart default) or already present cluster-wide.
2. Sync/upgrade the app chart (Argo or Helm) as usual.
3. Before promoting proxy min=2 to a tight Critical floor, check node free CPU/memory on `workload-class=critical`.
4. Dev GitOps should continue layering `values-dev.yaml` so expanded services keep minReplicas 1.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Critical MNG full → frontend-proxy Pending | Medium | High | maxReplicas 3; dev min 1; infra capacity follow-up |
| Higher steady cost | Medium | Low–Med | Dev mins; document budget |
| Cart multi-replica vs single Valkey | Low | Medium | Cart is stateless client; watch connections under soak |
| PDB blocks aggressive drains | Low | Low | minAvailable 1 with min 2 is standard |

**Rollback procedure:**

1. Revert this chart change or set each `components.*.autoscaling.enabled: false` and rely on default `replicas`.
2. `helm rollback` / Argo previous revision.
3. Delete leftover PDBs if needed after disable (or let next sync remove them).
