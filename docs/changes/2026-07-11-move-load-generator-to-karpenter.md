# Change: Move load-generator to Karpenter

## Summary

Reclassified `load-generator` from Critical MNG (`workload-class=critical`) to Karpenter hard placement (`workload-class=spot-tolerant` + Karpenter taint toleration) so synthetic load no longer competes with data-plane and observability pods on the small On-Demand system floor.

## Context

Critical MNG nodes (`t4g.medium`) were memory-saturated (~95%+) when load-generator (500Mi request) co-located with OpenSearch, Kafka, Argo, and observability. That pressure contributed to otel-collector agent health failures on the critical node. Load-generator is interruptible demo traffic, not a control-plane or stateful dependency — it belongs on the spot-tolerant Karpenter pool, matching the original placement plan and infra docs.

## Before

* `components.load-generator.schedulingRules: *scheduling-critical`
* Pod scheduled on Critical MNG only (no Karpenter toleration)
* Comment: “keep loadgen off Spot/Karpenter during placement rollout”

## After

* `components.load-generator.schedulingRules: *scheduling-spot-tolerant`
* Hard `nodeSelector.workload-class=spot-tolerant` + toleration `workload-class=spot-tolerant:NoSchedule`
* Preferred Spot capacity-type affinity (NodePool weight still owns Spot vs On-Demand fallback)
* Soft topology spreads from default contract
* Ops matrix updated so load-generator is listed under stateless / Karpenter

## Technical Design Decisions

* **Karpenter over Critical MNG** — load generation is elastic and Spot-safe; protecting the critical floor matters more than pinning Locust to On-Demand.
* **Reuse default spot-tolerant anchor** — no custom scheduling rules; same contract as frontend/catalog.
* **Keep resource requests** (200m / 500Mi) — Karpenter will provision capacity; no change required for placement move.
* **No infra Terraform** — NodePools and taints already support spot-tolerant workloads.

## Implementation Details

1. Switched `load-generator` YAML anchor from `*scheduling-critical` to `*scheduling-spot-tolerant` in `values.yaml`.
2. Updated `docs/operations/workload-placement.md` critical vs stateless lists and render matrix.
3. Live cluster: patched Deployment scheduling and rolled the pod onto a Karpenter node.

## Files Changed

**Configuration:**

* `values.yaml` — load-generator scheduling contract.

**Documentation:**

* `docs/operations/workload-placement.md` — classification and matrix.
* `docs/changes/2026-07-11-move-load-generator-to-karpenter.md` — this change record.

## Dependencies and Cross-Repository Impact

* Depends on Karpenter NodePools labeling/tainting `workload-class=spot-tolerant` (already deployed).
* Aligns chart with infra docs that already listed load-generator as Karpenter/stateless (`techx-corp-infra/docs/workload-placement.md`, `DEPLOYMENT.md`).
* Related capacity incident: `docs/changes/2026-07-11-fix-otel-agent-health-probe-storm.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Locust still targets `frontend-proxy`; may briefly reschedule during move |
| **Infrastructure** | Karpenter may provision an extra Spot/On-Demand node for 500Mi request |
| **Deployment** | Helm/Argo sync or Deployment patch rolls load-generator |
| **Reliability** | Critical MNG gains headroom; load-gen can be interrupted by Spot reclaim (acceptable for demo) |
| **Cost** | Slight Spot usage possible; Critical MNG less likely to need emergency scale-up |
| **Backward compatibility** | Service name/port unchanged |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass |
| Helm template | load-generator has spot-tolerant selector + toleration | ✅ Pass |

### Manual Verification

* Live pod on `ip-10-1-10-163`: `workload-class=spot-tolerant`, `karpenter.sh/nodepool=stateless-spot`, `capacity-type=spot`.
* Deployment `nodeSelector` / tolerations patched to spot-tolerant contract.
* Critical MNG no longer the target for new load-generator pods.

### Remaining Verification (Post-Merge)

* Argo sync chart so Git remains source of truth.
* Confirm Karpenter NodeClaim created if no existing capacity.

## Migration or Deployment Notes

1. Sync chart (or apply Deployment scheduling patch).
2. Expect one pod recreate; Karpenter may take 1–2 minutes if new capacity is needed.
3. Optional: after move, Critical MNG memory should drop by ~500Mi requests.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Spot interruption stops load-gen | Medium | Low | Acceptable for demo; NodePool On-Demand fallback may place OD node |
| Pending if Karpenter misconfigured | Low | Medium | Check NodePool Ready; temporarily revert to critical selector |

**Rollback procedure:**

1. Set `schedulingRules: *scheduling-critical` on load-generator.
2. Re-sync chart / roll Deployment.
