# Change: Soft Topology Spread Pod Balancing

## Summary

Added **soft** (`ScheduleAnyway`) topology spread constraints for default spot-tolerant workloads so multi-replica Deployments prefer multi-AZ and multi-node placement **within** the Karpenter pool, without changing Phase 1 hard `nodeSelector` / Karpenter toleration placement contracts. Critical workloads explicitly opt out to protect the small Critical MNG floor.

## Context

Phase 1 hard placement (critical MNG vs Karpenter spot-tolerant) is implemented. Topology spread was documented as a follow-up. Multi-replica HPA services (`frontend`, `checkout` at `minReplicas: 2`) could still pack onto a single node or zone when capacity allows more even distribution.

* Plan: workspace plan for pod placement balancing (topology spread)
* Must not regress hard placement canaries A/B/C

## Before

* `schedulingRules` supported only `nodeSelector`, `affinity`, and `tolerations`.
* No `topologySpreadConstraints` on first-party Deployments/StatefulSets.
* Critical and stateless contracts unchanged otherwise.

## After

* Default / `&scheduling-spot-tolerant` includes soft zone + hostname topology spreads.
* Critical / `&scheduling-critical` sets `topologySpreadConstraints: []` (opt-out).
* `templates/_objects.tpl` merges the new key with the same key-present full-replace semantics and injects `labelSelector` (`opentelemetry.io/name`) plus Deployment `matchLabelKeys: [pod-template-hash]`.
* Schema allows `topologySpreadConstraints` under `SchedulingRules`.
* Ops doc documents soft balancing and hard-placement invariants.

## Technical Design Decisions

* **Soft only (`ScheduleAnyway`)** — avoids Pending when only one AZ has free capacity (Karpenter scale-up, Spot scarcity).
* **Independent field** — not folded into `affinity`, so critical `affinity: {}` cannot accidentally clear or inherit spreads incorrectly.
* **Critical opt-out** — Critical MNG is small (`desired=1` per AZ); default zone spreads would risk unnecessary scheduling pressure on single-replica STS/edge pods.
* **Template-injected labelSelector** — avoids hard-coding component names in values; matches existing `techx-corp.selectorLabels`.
* **No infra Terraform** — multi-AZ capacity surface already exists; balancing is chart-side.

## Implementation Details

1. Extended `_objects.tpl` scheduling merge with `topologySpreadConstraints`.
2. For each constraint: emit `maxSkew` / `topologyKey` / `whenUnsatisfiable` / optional `minDomains`; inject labelSelector unless overridden; inject `matchLabelKeys` for non-StatefulSet when not explicitly set.
3. Updated `values.yaml` default and critical anchors.
4. Updated `values.schema.json`.
5. Updated `docs/operations/workload-placement.md`.

## Files Changed

**Templates:**

* `templates/_objects.tpl` — merge and render topology spread constraints.

**Configuration:**

* `values.yaml` — soft default spreads; critical empty opt-out; comments.
* `values.schema.json` — `topologySpreadConstraints` on SchedulingRules.

**Documentation:**

* `docs/operations/workload-placement.md` — soft balancing section and matrix.
* `docs/changes/2026-07-11-pod-topology-spread-balancing.md` — this change record.

## Dependencies and Cross-Repository Impact

* Depends on existing infra multi-AZ MNGs and Karpenter AZ allow-list for zone spread to have effect; soft mode still schedules with single-AZ capacity.
* Related docs cross-link: `techx-corp-infra/docs/workload-placement.md` and `techx-corp-infra/docs/changes/2026-07-11-pod-topology-spread-balancing.md`.
* No required Terraform apply for this chart change alone.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Multi-replica spot-tolerant pods prefer even zone/node distribution when capacity allows; hard placement unchanged |
| **Infrastructure** | No Terraform change in this repo |
| **Deployment** | Helm/Argo sync updates pod templates; rolling updates may gently rebalance new pods only (not a descheduler) |
| **Performance** | Negligible scheduler overhead |
| **Security** | No change |
| **Reliability** | Soft constraints cannot alone cause Pending; improves AZ resilience for HPA apps when multi-AZ capacity exists |
| **Cost** | No direct change; may slightly increase chance of multi-node Spot usage vs packing |
| **Backward compatibility** | Fully backward-compatible for single-replica and critical opt-out workloads |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (dev) | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass |
| Helm lint (prod) | `helm lint . -f values.yaml -f values-prod.yaml` | ✅ Pass |
| Render + assert | `helm template test . -f values.yaml -f values-dev.yaml` | ✅ Pass — frontend/checkout/product-catalog soft zone+hostname spreads + hard spot-tolerant; frontend-proxy/postgresql/load-generator critical only, no topologySpreadConstraints |

### Manual Verification

* Rendered `frontend` / `checkout` retain `workload-class=spot-tolerant` + Karpenter toleration and gain soft topology spreads with injected `opentelemetry.io/name` labelSelector and `matchLabelKeys: [pod-template-hash]`.
* Rendered `frontend-proxy` / `postgresql` / `load-generator` retain `workload-class=critical`, no Karpenter toleration, no topologySpreadConstraints.

### Remaining Verification (Post-Merge)

* Sync chart in development; inspect `kubectl get pods -o wide` for frontend/checkout zone distribution when ≥2 eligible nodes exist.
* Re-run Phase 1 placement canaries A/B/C.

## Migration or Deployment Notes

1. Infra hard-placement (labels/taints/NodePools) must already be live.
2. Sync this chart via Argo CD / Helm as usual — no special ordering beyond existing chart-after-infra rule.
3. Existing pods are not rebalanced until replaced (rollout, scale, node drain).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Soft spreads ignored under single-zone capacity | Medium | Low | Expected; not a failure |
| Merge bug critical inherits spreads | Low | Medium | Explicit `[]` opt-out + render checks |
| Rolling update thrash | Low | Low | `matchLabelKeys: pod-template-hash` on Deployments |

**Rollback procedure:**

1. Set `default.schedulingRules.topologySpreadConstraints: []` or revert this change.
2. Re-sync Helm/Argo — hard placement remains intact.
3. No Terraform rollback.
