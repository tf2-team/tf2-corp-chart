# Change: Remove HPA for load-generator

## Summary

Disabled Horizontal Pod Autoscaler for `load-generator` so the Deployment stays at a fixed replica count (chart default). Synthetic traffic intensity is controlled via Locust configuration (`LOCUST_USERS`, UI ramp), not pod scale-out.

## Context

`load-generator` previously used dual-metric HPA (CPU 70% / memory 90%, min 1 / max 6). With `LOCUST_AUTOSTART`, each replica independently runs a full `LOCUST_USERS` swarm rather than sharing Locust distributed master/worker mode. HPA scale-out therefore multiplies baseline synthetic traffic and can drive unnecessary Karpenter capacity. Operators should ramp load via Locust settings instead.

* Related prior work: `docs/changes/2026-07-11-add-load-generator-hpa.md`
* Placement remains Karpenter `spot-tolerant` (`docs/changes/2026-07-11-move-load-generator-to-karpenter.md`)

## Before

* `components.load-generator.autoscaling.enabled: true` with min 1 / max 6, CPU 70%, memory 90%, shared HPA behavior.
* Helm rendered `HorizontalPodAutoscaler/load-generator`; Deployment omitted static `replicas` when HPA was enabled.
* Ops docs listed load-generator in the default HPA inventory.

## After

* `components.load-generator` has **no** `autoscaling` block (HPA not rendered).
* Deployment uses chart default fixed `replicas` (typically `1`).
* Ops docs state load-generator is fixed-replica; HPA describe commands omit it.

## Technical Design Decisions

* **Remove HPA rather than set `enabled: false` only** — clearer intent and avoids leaving an unused dual-metric block that invites re-enablement without revisiting Locust semantics.
* **No Locust distributed mode** — re-adding multi-replica scale would need master/worker design; out of scope.
* **Ramp path** remains env/UI (`LOCUST_USERS`, spawn rate, browser traffic flags).

## Implementation Details

1. Removed `components.load-generator.autoscaling` from `values.yaml` and replaced with a comment describing fixed-replica / Locust-ramp intent.
2. Updated `docs/DEPLOYMENT.md` HPA inventory, describe command, and expectations.
3. Updated `docs/operations/workload-placement.md` multi-replica HPA table row for load-generator.
4. Added this change record.

## Files Changed

**Configuration:**
* `values.yaml` — Removed load-generator autoscaling block; fixed-replica comment.

**Documentation:**
* `docs/DEPLOYMENT.md` — HPA inventory and verification commands no longer include load-generator HPA.
* `docs/operations/workload-placement.md` — load-generator HPA note set to none / fixed replicas.
* `docs/changes/2026-07-11-remove-load-generator-hpa.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only; Metrics Server and other service HPAs unchanged.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | load-generator no longer scales pod count under CPU/memory pressure; traffic level follows Locust config on a fixed pod count |
| **Infrastructure** | Fewer opportunistic Karpenter nodes solely for load-generator HPA scale-out |
| **Deployment** | Helm/Argo sync deletes `HorizontalPodAutoscaler/load-generator` if previously applied; Deployment gains static `replicas` |
| **Performance** | N/A for user-facing services; synthetic load ceiling is one Locust swarm per configured replica |
| **Security** | No change |
| **Reliability** | Avoids accidental multi-swarm traffic spikes from HPA scale-out |
| **Cost** | Slightly lower risk of extra spot-tolerant capacity for load-gen scale-out |
| **Backward compatibility** | Removes previously rendered HPA object; operators who relied on multi-pod load-gen must use Locust settings or re-enable autoscaling deliberately |
| **Observability** | No change to metrics stack; `kubectl get hpa` no longer shows load-generator |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values edit | Inspect `components.load-generator` — no `autoscaling` key | ✅ Pass |
| Template | `helm template test . -f values.yaml` — no HPA named `load-generator`; Deployment has `replicas: 1`; five HPAs remain (frontend, checkout, cart, product-catalog, frontend-proxy) | ✅ Pass |

### Manual Verification

* After sync: `kubectl -n techx-corp get hpa load-generator` → NotFound
* `kubectl -n techx-corp get deploy load-generator -o jsonpath='{.spec.replicas}'` → fixed (e.g. `1`)

### Remaining Verification (Post-Merge)

* Argo/Helm sync on target env; confirm HPA removed and pod count stable.
* Operator action: if residual HPA exists only as orphan, delete after chart no longer owns it (Helm normally prunes).

## Migration or Deployment Notes

1. Sync chart (Argo CD or Helm upgrade).
2. Confirm `HorizontalPodAutoscaler/load-generator` is gone.
3. Confirm Deployment `replicas` is set (not HPA-managed).
4. Adjust synthetic load only via `LOCUST_USERS` / Locust UI / related env flags.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operators expected auto scale-out under heavy Locust UI ramps | Low | Low | Document ramp via Locust; re-enable HPA only with distributed-mode design |
| Existing scaled replica count temporarily higher until Deployment settles | Low | Low | Scale Deployment to desired count after HPA removal if needed |

**Rollback procedure:**

Restore the `components.load-generator.autoscaling` block from `docs/changes/2026-07-11-add-load-generator-hpa.md` / prior commit and re-sync.
