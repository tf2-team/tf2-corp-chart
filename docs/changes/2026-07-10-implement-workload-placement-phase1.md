# Change: Implement Workload Placement Phase 1 (Chart Scheduling)

## Summary

Applied soft workload placement in the umbrella chart: default pods prefer Karpenter Spot / spot-tolerant nodes; stateful data components require `workload-class=critical` (managed node groups); production pins edge control plane (`frontend-proxy`, `flagd`); metrics-server pins critical. Template merge fixed so critical overrides clear default Spot affinity.

## Context

Infrastructure labels MNG as critical and Karpenter as spot-tolerant (`techx-corp-infra` workload placement). Without chart `schedulingRules`, pods still pack freely. This change enforces the application side of the strategy.

## Before

* `default.schedulingRules` empty (no affinity / selectors).
* Stateful components had no placement rules.
* metrics-server unpinned.
* Template used `default` filter for scheduling keys so empty maps did not reliably clear defaults.

## After

* **Default:** preferred nodeAffinity for `karpenter.sh/capacity-type=spot` (weight 100) and `workload-class=spot-tolerant` (weight 50).
* **Critical STS:** `postgresql`, `kafka`, `valkey-cart`, `opensearch` → `nodeSelector.workload-class=critical`, empty affinity.
* **values-prod:** `frontend-proxy` and `flagd` critical.
* **metrics-server:** `nodeSelector.workload-class=critical`.
* **Template:** per-key replace via `hasKey` / `ternary` so component empty affinity removes Spot prefer.
* Ops note: `docs/operations/workload-placement.md`.

## Technical Design Decisions

* Soft preferred Spot for apps (not hard Spot-only) so On-Demand Karpenter fallback still works.
* Critical data uses required nodeSelector only (no Spot preference).
* Prod-only edge pins keep dev debugging flexibility for frontend-proxy.
* YAML anchors for critical/spot rule blocks to avoid drift.

## Implementation Details

1. Updated `default.schedulingRules` with Spot preferred affinity (YAML anchor).
2. Set critical scheduling on four stateful components (shared anchor).
3. Prod overlay critical for frontend-proxy and flagd.
4. Fixed `_objects.tpl` scheduling merge semantics.
5. metrics-server subchart nodeSelector.
6. Documented chart-side ops.

## Files Changed

**Templates / values:**

* `templates/_objects.tpl` — schedulingRules merge fix.
* `values.yaml` — default Spot prefer; critical STS; metrics-server pin.
* `values-dev.yaml` — note (frontend-proxy inherits Spot prefer).
* `values-prod.yaml` — frontend-proxy + flagd critical.

**Documentation:**

* `docs/operations/workload-placement.md` — chart ops guide.
* `docs/changes/2026-07-10-implement-workload-placement-phase1.md` — this record.

## Dependencies and Cross-Repository Impact

* **Depends on** infra MNG labels `workload-class=critical` and Karpenter node labels.  
  Related: `techx-corp-infra/docs/changes/2026-07-10-implement-workload-placement-phase1.md`
* Sync chart only after Terraform has labeled nodes (or critical pods Pending).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Critical STS only on critical nodes; apps prefer Spot when available |
| **Infrastructure** | No Terraform change in this repo |
| **Deployment** | Helm upgrade / Argo sync; may reschedule pods |
| **Performance** | Possible brief reschedule; Spot reclaim affects only spot-tolerant tier |
| **Reliability** | Stateful data isolated from Spot reclaim (when MNG is On-Demand) |
| **Backward compatibility** | Requires labeled nodes; otherwise critical Pending |
| **Observability** | metrics-server on critical floor for HPA stability |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm template (placement matrix) | `helm template test . -f values.yaml -f values-prod.yaml` | ✅ Critical STS: critical_ns only; apps: spot affinity; prod edge critical |
| metrics-server | Rendered Deployment includes `nodeSelector.workload-class=critical` | ✅ Pass |

### Manual Verification

* Python placement matrix: kafka/postgresql/valkey-cart/opensearch/flagd/frontend-proxy critical without Spot affinity; cart/checkout/frontend Spot prefer.

### Remaining Verification (Post-Merge)

```bash
# After infra labels + Argo/Helm sync
kubectl get pod -o wide
kubectl get nodes -L workload-class
```

## Migration or Deployment Notes

1. Ensure MNG nodes have `workload-class=critical` before syncing this chart.
2. Expect reschedule of stateful pods onto MNG if they were on Karpenter.
3. Phase 2 taints not enabled — no tolerations required yet.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Critical Pending if labels missing | Medium | High | Apply infra first; temporary remove nodeSelector |
| MNG capacity pressure from all critical STS | Medium | Medium | Size MNG / limits; leave non-data on Spot |

**Rollback procedure:**

Revert `values.yaml` / overlays / `_objects.tpl` to prior revision and re-sync; pods schedule without tier constraints again.
