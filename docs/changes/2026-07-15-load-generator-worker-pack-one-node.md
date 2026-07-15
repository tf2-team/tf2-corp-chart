# Change: Prefer packing load-generator-worker scale-out on one node first

## Summary

Changed `load-generator-worker` scheduling so HPA scale-out **prefers filling one Spot node before spreading** across nodes/AZs. Soft same-worker hostname `podAffinity` packs new workers next to existing ones; default soft topology spreads are opted out. Hard storefront node anti-affinity and spot-tolerant placement remain.

## Context

Default spot-tolerant topology spreads (`maxSkew: 1` on zone and hostname, `ScheduleAnyway`) encourage multi-node distribution. Locust workers are cost-elastic load tools, not HA money-flow services: spreading them across nodes often provisions extra Karpenter Spot capacity during scale-out. Operators want scale-up to prefer one node first to densify workers and reduce node sprawl.

* Related: `docs/changes/2026-07-14-distributed-load-generator.md`, `docs/changes/2026-07-11-pod-topology-spread-balancing.md`, `docs/operations/workload-placement.md`.

## Before

`components.load-generator-worker.schedulingRules`:

* Hard `nodeSelector` / Karpenter toleration for `spot-tolerant`.
* Required `podAntiAffinity` vs storefront services on `kubernetes.io/hostname`.
* No component `topologySpreadConstraints` key → inherited default soft zone + hostname spreads.
* Component `affinity` full-replace dropped default preferred Spot `nodeAffinity`.

Scale-out therefore preferred multi-node balancing when free capacity existed on other nodes.

## After

Worker-only scheduling overrides:

* `topologySpreadConstraints: []` — opt out of default soft multi-node/AZ spreads.
* Preferred `podAffinity` weight 100 on hostname for pods with `app.kubernetes.io/name=load-generator-worker` — pack new workers onto a node that already runs a worker when capacity allows.
* Restated preferred Spot capacity-type `nodeAffinity` (affinity key fully replaces defaults).
* Unchanged: hard storefront anti-affinity, spot-tolerant selector/toleration, HPA behavior.

When the preferred node is full, preferred affinity does not block scheduling; Karpenter may still add nodes.

## Technical Design Decisions

* **Soft pack (preferred affinity)** rather than required affinity — required co-location would risk Pending / stuck scale-out when the first worker’s node is full or reclaimed.
* **Topology opt-out** — default spreads fight packing; empty list is the existing critical-style opt-out pattern in this chart.
* **Keep hard storefront anti-affinity** — workers must not land on nodes hosting commerce pods.
* **Restate Spot preference** — component affinity replace would otherwise lose default Spot prefer.
* Alternatives rejected: raise HPA max only (does not fix packing); descheduler (out of scope); required affinity (can strand scale-out).

## Implementation Details

1. Extended `load-generator-worker.schedulingRules` in `values.yaml` with pack-first affinity and topology opt-out.
2. Updated operator placement and deployment docs.
3. No template change — `_objects.tpl` already supports full-replace of `affinity` and empty `topologySpreadConstraints`.

## Files Changed

**Configuration:**

* `values.yaml` — Worker scheduling: preferred same-worker hostname pack, Spot prefer restated, topology spreads cleared.

**Documentation:**

* `docs/operations/workload-placement.md` — Worker contract and render matrix note pack-first exception.
* `docs/DEPLOYMENT.md` — Locust worker note includes pack-on-one-node behavior.
* `docs/changes/2026-07-15-load-generator-worker-pack-one-node.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only scheduling; platform Locust image and infra NodePools unchanged. Karpenter consolidation still benefits from denser packing when HPA scales down.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Multi-worker Locust scale-out prefers fewer nodes; load semantics unchanged |
| **Infrastructure** | Fewer opportunistic Spot nodes during moderate worker scale-out |
| **Deployment** | Argo/Helm sync rolls `load-generator-worker` Deployment pod template |
| **Performance** | Negligible; dense workers share node CPU — requests/limits still cap per pod |
| **Security** | No change |
| **Reliability** | Soft preferences cannot alone cause Pending; storefront isolation retained |
| **Cost** | Lower expected Spot node count under partial worker scale-out |
| **Backward compatibility** | Fully compatible; scheduling preference only |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values inspect | `components.load-generator-worker.schedulingRules` | ✅ topology `[]`, preferred worker pack affinity, storefront anti-affinity, Spot prefer |
| Helm lint | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass |
| Helm template | Worker Deployment has pack affinity and no topologySpreadConstraints | ✅ Preferred hostname `podAffinity` + storefront anti-affinity; no spread constraints rendered |

### Manual Verification

After sync:

```cmd
kubectl -n techx-corp-prod get deploy load-generator-worker -o yaml
kubectl -n techx-corp-prod get pods -l opentelemetry.io/name=load-generator-worker -o wide
```

Expect no `topologySpreadConstraints` on the pod template; affinity includes preferred `load-generator-worker` hostname term. With ≥2 ready workers and free capacity on the first worker’s node, new pods should land on that hostname first.

### Remaining Verification (Post-Merge)

* Operator: scale workers (or wait for HPA) and confirm packing via `kubectl get pods -o wide` before additional Karpenter nodes appear.

## Migration or Deployment Notes

1. Commit/push chart change; allow Argo CD auto-sync (no direct Helm upgrade).
2. Rolling restart of workers is expected from pod template change; Locust master re-registers workers.
3. No infra apply required.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Dense packing saturates one Spot node CPU under high `LOCUST_USERS` | Medium | Low | Per-pod limits still enforce; HPA still scale-out; soft affinity allows other nodes when full |
| Pack preference weaker than other schedulers scores | Low | Low | Accept; still better than forced multi-node spread |

**Rollback procedure:**

Revert `components.load-generator-worker.schedulingRules` to prior affinity-only block (storefront anti-affinity, no topology opt-out, no pack affinity) and re-sync GitOps.

<!-- Change trail: @hungxqt - 2026-07-15 - Pack load-generator-worker scale-out on one node first. -->
