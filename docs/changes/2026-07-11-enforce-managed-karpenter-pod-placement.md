# Change: Enforce Hard Pod Placement (Critical MNG vs Karpenter)

## Summary

Upgraded the umbrella chart from soft Spot preference to **hard placement**: default workloads require `workload-class=spot-tolerant` and tolerate the Karpenter taint; critical workloads (data, edge gateway, observability, metrics-server) require `workload-class=critical` without Karpenter toleration; OTel agent remains a universal DaemonSet with the Karpenter toleration only.

## Context

Infrastructure now taints Karpenter nodes with `workload-class=spot-tolerant:NoSchedule` and labels Critical MNG with `workload-class=critical`. Soft preferred affinity no longer matches that contract and would leave classified apps Pending or still packing onto MNG.

* Plan: workspace `docs/plan/13422026.md`
* Infra counterpart: `techx-corp-infra/docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md`

## Before

* `default.schedulingRules`: empty nodeSelector; preferred Spot + spot-tolerant affinity; no Karpenter toleration.
* Critical STS only: postgresql, kafka, valkey-cart, opensearch.
* frontend-proxy / flagd critical only via overlays (prod primarily).
* Prometheus / Grafana / Jaeger unpinned.
* OTel agent: no explicit Karpenter taint toleration.

## After

* **Default (stateless):** hard `nodeSelector.workload-class=spot-tolerant`, Spot capacity-type preferred affinity (secondary), toleration for `workload-class=spot-tolerant:NoSchedule`.
* **Critical:** frontend-proxy, flagd, postgresql, kafka, valkey-cart, opensearch; metrics-server; prometheus.server; grafana; jaeger.jaeger — `nodeSelector.workload-class=critical`, no Karpenter toleration.
* **Explicit stateless examples:** frontend, product-catalog, recommendation (also covered by default for other first-party apps).
* **load-generator** pinned critical (Critical MNG / system-*), not Karpenter.
* **Universal:** opentelemetry-collector DaemonSet tolerates Karpenter taint; no workload-class selector.
* Ops doc rewritten for hard-placement matrix, inventory validation, and canaries.

## Technical Design Decisions

* Reuse existing `schedulingRules` merge (no new schema/framework).
* Spot affinity remains preference only; NodePool weight in infra owns Spot vs On-Demand order.
* frontend ≠ frontend-proxy (stateless vs critical gateway).
* One-way isolation: unclassified pods without Karpenter toleration can still use MNG.

## Implementation Details

1. Updated `default.schedulingRules` hard contract + YAML anchor.
2. Defined critical anchor on `frontend-proxy`; aliased STS/data components.
3. Pinned flagd critical in base values; simplified overlays.
4. Pinned prometheus/grafana/jaeger nodeSelectors.
5. Added OTel Karpenter toleration.
6. Updated `docs/operations/workload-placement.md`.

## Files Changed

**Values / templates:**

* `values.yaml` — hard default, critical list, OTel toleration, observability pins, explicit stateless examples.
* `values-dev.yaml` / `values-prod.yaml` — remove redundant critical overrides (contract in base).

**Documentation:**

* `docs/operations/workload-placement.md` — hard-placement ops guide.
* `docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md` — this record.

## Dependencies and Cross-Repository Impact

* **Depends on** infra system/critical labels and Karpenter taints before or with sync.  
  Related: `techx-corp-infra/docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md`
* Sync only after: system MNG Ready, capacity preflight, controller pins, universal DaemonSet toleration gate, NodePools Ready.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Classified stateless pods cannot schedule on MNG; critical cannot schedule on Karpenter |
| **Infrastructure** | No Terraform in this repo |
| **Deployment** | Helm/Argo sync causes reschedule; may Pending until Karpenter provisions |
| **Reliability** | Stronger isolation; risk of Pending if infra lagging |
| **Backward compatibility** | Requires labeled+tainted node pools matching contract |
| **Observability** | Metrics stack pinned to critical floor |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (dev overlay) | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass |
| Helm template inventory | `helm template` + placement assertions | ✅ Critical/stateless/universal matrix matched for listed workloads |

### Manual Verification

Rendered (dev) inventory sample:

| Kind | Workload | Contract | Selector | Karpenter toleration |
|------|----------|----------|----------|----------------------|
| Deployment | frontend | stateless | spot-tolerant | Yes |
| Deployment | frontend-proxy | critical | critical | No |
| StatefulSet | postgresql/kafka/… | critical | critical | No |
| DaemonSet | otel-collector-agent | universal | none | Yes |
| Deployment | prometheus/grafana/jaeger | critical | critical | No |

### Remaining Verification (Post-Merge)

* Live pod→node placement after infra apply + Argo/Helm sync.
* Canaries A/B/C and `scripts/smoke-test.sh`.
* Full rendered inventory including Jobs/hooks for intentionally unclassified workloads.

## Migration or Deployment Notes

1. Infra first (labels, system MNG, Karpenter taints).
2. Sync chart; watch Pending / FailedScheduling.
3. Do not cordon legacy MNG until chart sync is healthy.
4. Rollback chart alone if placement fails while keeping Karpenter 1.13.1.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Pending if taints applied before chart | Medium | High | Order: universal DS gate → taints → chart; or temporary remove taints |
| Critical Pending if system MNG not Ready | Medium | High | Capacity preflight; dual-run legacy |
| Unclassified pods on MNG steal capacity | Medium | Medium | Inventory; later admission/MNG taint |

**Rollback procedure:**

Revert `values.yaml` / overlays / ops doc to prior soft-placement revision and re-sync. Prefer uncordon legacy MNG over Karpenter version downgrade.
