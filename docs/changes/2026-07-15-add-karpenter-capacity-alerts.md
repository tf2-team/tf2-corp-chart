# Change: Add Karpenter Capacity Alerts

## Summary

Add Prometheus scraping for the in-cluster Karpenter metrics endpoint, expose only the node labels needed for placement-aware capacity queries, provision Grafana alerts for Karpenter health, NodePool limits, production unschedulable pods, and critical-node request headroom, and document the runtime evidence required before changing workload resource requests.

## Context

Read-only inspection found that Karpenter exposed scheduler, synchronization, and NodePool usage/limit metrics on its `http-metrics` service, but the chart-managed Prometheus did not scrape them. Kube-state-metrics was scraped without the node-label allowlist required to distinguish Critical MNG capacity. The scaling plan also requires representative load evidence before resource requests change; no qualifying 30-minute sample was collected in this implementation.

## Before

* Prometheus did not contain a Karpenter scrape job.
* Kube-state-metrics did not expose the bounded workload-class/NodePool/capacity-type node labels.
* Grafana had generic pod health alerts but no Karpenter synchronization, scheduler, or NodePool-limit rules.
* Resource-request validation and critical-capacity thresholds were not collected in one operator runbook.

## After

* Prometheus scrapes `karpenter.kube-system.svc.cluster.local:8080` as job `karpenter`.
* Kube-state-metrics exposes only `workload-class`, `karpenter.sh/nodepool`, `karpenter.sh/capacity-type`, and `topology.kubernetes.io/zone` from node labels.
* Grafana provisions warnings for Karpenter unschedulable pods, NodePool CPU/memory above 80%, and production unschedulable pods after 5 minutes.
* Grafana provisions critical rules for Karpenter cluster-state desynchronization and production unschedulable pods after 15 minutes.
* Critical MNG requested CPU/memory above 75% raises a warning.
* Existing workload resource requests remain unchanged pending representative evidence.

## Technical Design Decisions

The scrape target uses the stable in-cluster Service DNS and read-only metrics port rather than pod IPs. Node-label exposure is an explicit allowlist rather than a wildcard to constrain cardinality and avoid publishing unrelated labels. Alerts use metric names verified from the live Karpenter endpoint. `noDataState` is `Error` for synchronization and critical-headroom rules because missing foundational data makes those safety checks indeterminate; capacity and Pending rules use `OK` when the corresponding series is absent.

The request runbook uses P95 measurements and maximum-replica footprint instead of guessing from current requests. No resource value is changed without the required evidence.

## Implementation Details

1. Added a Karpenter static scrape job under the Prometheus server values.
2. Added the minimum kube-state-metrics node-label allowlist used by capacity queries.
3. Added a Grafana provisioning file with Karpenter, Pending-pod, NodePool-limit, and critical-headroom rules.
4. Added an operator runbook for read-only inspection, Prometheus evidence, request formulas, and scale-out/scale-in gates.

## Files Changed

**Configuration:**

* `values.yaml` — Adds Karpenter scraping and bounded node-label metrics.
* `grafana/provisioning/alerting/karpenter-capacity-alerting.yaml` — Adds the capacity and scheduling alert group.

**Documentation:**

* `docs/operations/autoscaling-validation.md` — Defines validation and resource-evidence gates.
* `docs/changes/2026-07-15-add-karpenter-capacity-alerts.md` — This change record.

## Dependencies and Cross-Repository Impact

The alerts expect Karpenter and kube-state-metrics metric names available in the current cluster. The Karpenter lifecycle and NodePool policy are maintained in `techx-corp-infra`; related change record: `techx-corp-infra/docs/changes/2026-07-15-harden-karpenter-scaling.md`. No infra file is modified by this chart change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No application API or workload-request change. |
| **Infrastructure** | No Terraform change; Prometheus performs one additional in-cluster scrape. |
| **Deployment** | Argo CD reconciles the chart after normal Git review. |
| **Performance** | Small additional scrape and node-label series; wildcard label collection is not enabled. |
| **Security** | Metrics stay in-cluster and no Secret data is scraped; node labels are narrowly allowlisted. |
| **Reliability** | Adds early warning for scheduler, capacity, synchronization, Pending-pod, and Critical-MNG headroom failures. |
| **Cost** | Negligible metrics cardinality increase; no NodePool limit or replica change. |
| **Backward compatibility** | Additive chart values and provisioning file; existing workloads remain unchanged. |
| **Observability** | Adds one Prometheus job and six Grafana rules. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Chart lint | `helm lint . -f values-public-alb.yaml -f values-prod.yaml` | ✅ Pass; one chart, zero failures |
| Directive policy regression | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-directive-03.ps1` | ✅ Pass for all workloads, flagd secret reference, and active-HPA PDB ownership |
| Production render assertions | `helm template techx-corp . -n techx-corp-prod -f values-public-alb.yaml -f values-prod.yaml` | ✅ Karpenter scrape, node-label allowlist, alert group, and critical-headroom rule rendered |
| Whitespace validation | `git diff --check` | ✅ Pass |

### Manual Verification

Read-only live inspection confirmed the Karpenter Service port and the metric names used by the rules. Runtime alert evaluation is not claimed before Argo CD reconciliation.

### Remaining Verification (Post-Merge)

* Confirm Prometheus target `karpenter` is up after sync.
* Confirm `kube_node_labels{label_workload_class="critical"}` is present without unrelated node labels.
* Evaluate every alert query in Grafana Explore and verify notification routing with the approved non-production test procedure.
* Run the development scale-out/scale-in evidence window before production promotion.

## Migration or Deployment Notes

1. Merge through the normal chart repository workflow; Argo CD is the only deployment path.
2. After reconciliation, verify the Karpenter target and kube-state-metrics label series.
3. Evaluate each rule in Grafana Explore before relying on notification delivery.
4. Do not mutate the release with direct Helm or kubectl commands.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Karpenter Service DNS or port changes | Low | Medium | Target-down/desynchronization becomes visible; update the Git value after read-only verification. |
| Alert query label mismatch | Medium | Medium | Evaluate queries after sync; revert the provisioning file if noisy or indeterminate. |
| Additional labels increase cardinality | Low | Low | Four node labels are explicitly allowlisted; no wildcard is used. |
| Hard topology produces intentional Pending pods | Medium | Medium | Investigate capacity/AZ health before any approved incident relaxation. |

**Rollback procedure:**

Revert these chart files in Git and allow Argo CD to reconcile. Do not use direct `helm rollback` or mutating kubectl commands.

<!-- Change trail: @hungxqt - 2026-07-15 - Record Karpenter metrics and capacity alert provisioning. -->
