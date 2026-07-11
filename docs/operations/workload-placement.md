# Workload Placement (Chart)

This chart implements **hard placement** between Critical MNG and Karpenter, plus **soft topology balancing** for multi-replica stateless pods. Infrastructure labels, taints, NodePool weights, and capacity policy live in `techx-corp-infra` — see that repo’s `docs/workload-placement.md`.

## Placement contracts

| Contract | Mechanism | Workloads |
|----------|-----------|-----------|
| **Critical** | `nodeSelector.workload-class=critical`; **no** Karpenter toleration; **no** topology spreads (`topologySpreadConstraints: []`) | `frontend-proxy`, `flagd`, `postgresql`, `kafka`, `valkey-cart`, `opensearch`, `prometheus.server`, `grafana`, `jaeger.jaeger`, `metrics-server` |
| **Stateless (default)** | `nodeSelector.workload-class=spot-tolerant` + toleration `workload-class=spot-tolerant:NoSchedule` + preferred Spot affinity + **soft** zone/hostname topology spreads | All first-party Deployments that inherit `default.schedulingRules` (explicit: `frontend`, `product-catalog`, `recommendation`, `load-generator`, and other classified demo apps) |
| **Universal DaemonSet** | No workload-class selector; Karpenter taint toleration | `opentelemetry-collector` (agent DaemonSet) |

### Important distinctions

* **`frontend`** is stateless → Karpenter.
* **`frontend-proxy`** is critical ingress/gateway → Critical MNG.
* Spot capacity-type affinity is a **preference only**. Primary vs On-Demand fallback is decided by **NodePool weight** in infra, not by chart affinity alone.
* Isolation is **one-way**: classified critical pods cannot land on Karpenter; classified stateless pods cannot land on MNG; **unclassified** pods without the Karpenter toleration can still schedule on MNG.
* Topology spread is **additive soft balancing** only. It never replaces `nodeSelector` / tolerations and uses `whenUnsatisfiable: ScheduleAnyway` so capacity in a single AZ cannot leave pods Pending.

### Multi-replica HPA vs placement

| Service | HPA (base) | Contract | Note |
|---------|------------|----------|------|
| `frontend`, `checkout`, `cart`, `product-catalog` | min **1** / max 6 (CPU 70% + Mem 90%) | spot-tolerant | Karpenter can add nodes under scale-out; memory is safety valve only |
| `load-generator` | **none** (fixed replicas) | spot-tolerant | Ramp via `LOCUST_USERS` / Locust UI; not Locust distributed mode — extra pods would each run independent swarms |
| `frontend-proxy` | min **1** / max **3** (CPU 70% + Mem 90%) | critical | Extra replicas **do not** land on Karpenter; Critical MNG is small (`desired`/`max` in infra). Pending proxy pods → capacity on Critical floor, not chart max increase |

PDBs (`minAvailable: 1`) are rendered for HPA services with `minReplicas >= 2` (none at current floor of 1). Soft topology spreads apply only on the spot-tolerant pool (critical opts out).

## Pod distribution (topology spread)

Default (spot-tolerant) contract includes:

| Constraint | `topologyKey` | `whenUnsatisfiable` | Purpose |
|------------|---------------|---------------------|---------|
| Zone | `topology.kubernetes.io/zone` | `ScheduleAnyway` | Prefer multi-AZ distribution of replicas |
| Node | `kubernetes.io/hostname` | `ScheduleAnyway` | Prefer not packing all replicas on one node |

* `labelSelector` is **template-injected** as `opentelemetry.io/name: <component>` (matches `techx-corp.selectorLabels`).
* Deployments also get `matchLabelKeys: [pod-template-hash]` so rolling updates do not skew against old ReplicaSet pods.
* Critical workloads **opt out** with `topologySpreadConstraints: []` to protect the small Critical MNG floor (`desired=1` per AZ).
* Soft spreads on single-replica Deployments are effectively a no-op.

Hard `DoNotSchedule` zone constraints, PriorityClass, and MNG taints remain separate follow-ups. First-party **PDB** for multi-replica HPA Deployments is implemented (`templates/pdb.yaml`).

## Template behavior

`templates/_objects.tpl` merges `default.schedulingRules` with per-component `schedulingRules`. When a component sets a key (`nodeSelector`, `affinity`, `tolerations`, or `topologySpreadConstraints`), that key **fully replaces** the default — including empty maps/lists so critical workloads clear Spot affinity, Karpenter tolerations, and default soft spreads.

## Overlays

* **values-dev.yaml** / **values-prod.yaml** — image tags, ALB path blocking, secrets; critical/stateless contracts live in base `values.yaml`.

## Prerequisites

1. Critical MNG nodes labeled `workload-class=critical` (`system-*`, and legacy `general-*` during dual-run).
2. Karpenter NodePools label + taint `workload-class=spot-tolerant:NoSchedule`.
3. Universal DaemonSets (VPC CNI, kube-proxy, ebs-csi-node, OTel agent) tolerate the Karpenter taint **before** taint is applied.
4. Apply/sync **infra first**, then this chart.
5. Multi-AZ private subnets / Karpenter AZ allow-list for zone spread to have an effect (soft spreads still schedule if only one AZ has capacity).

## Rendered inventory validation

Validate **all** PodTemplates, not only Deployments:

```text
Deployment, StatefulSet, DaemonSet, Job, CronJob, Helm hooks, test Pods
```

```bash
helm lint . -f values.yaml -f values-dev.yaml
helm template test . -f values.yaml -f values-dev.yaml > /tmp/render-dev.yaml
helm template test . -f values.yaml -f values-prod.yaml > /tmp/render-prod.yaml
```

Expected matrix (selected):

| Kind | Workload | Contract | Selector | Karpenter toleration | Topology spread |
|------|----------|----------|----------|----------------------|-----------------|
| Deployment | frontend | stateless | `spot-tolerant` | Yes | Soft zone + hostname |
| Deployment | checkout | stateless | `spot-tolerant` | Yes | Soft zone + hostname |
| Deployment | load-generator | stateless | `spot-tolerant` | Yes | Soft zone + hostname |
| Deployment | frontend-proxy | critical | `critical` | No | None (opt-out) |
| StatefulSet | postgresql / kafka / … | critical | `critical` | No | None (opt-out) |
| DaemonSet | otel-collector-agent | universal | none | Yes | N/A |
| Deployment | prometheus / grafana / jaeger | critical | `critical` | No | N/A (subchart pins) |

List any intentionally unclassified workload explicitly during acceptance review.

## Live verification

```bash
kubectl get nodes -L workload-class,topology.kubernetes.io/zone,karpenter.sh/capacity-type,role,karpenter.sh/nodepool
kubectl get pod -A -o wide

# Critical only on system-* (or labeled critical MNG during dual-run)
# Stateless only on Karpenter nodes (workload-class=spot-tolerant)
# OTel agent on both layers

# Multi-replica stateless distribution (when ≥2 eligible nodes/zones exist):
kubectl get pods -n <ns> -l opentelemetry.io/name=frontend -o wide
kubectl get pods -n <ns> -l opentelemetry.io/name=checkout -o wide
```

Soft spreads prefer multi-zone placement when capacity allows; if only one zone has free capacity, pods must still Schedule.

## Canaries (runtime acceptance)

| Canary | Spec | Expected |
|--------|------|----------|
| A | No selector, no Karpenter toleration | Schedules on MNG |
| B | `nodeSelector.workload-class=spot-tolerant` without toleration | Pending |
| C | Selector spot-tolerant + capacity-type on-demand + toleration | Karpenter On-Demand node |

Topology spreads must not change A/B/C outcomes.

## Rollback (chart only)

1. Set `default.schedulingRules.topologySpreadConstraints: []` (or revert this change) and re-sync — hard placement remains.
2. Full hard-placement rollback: revert hard `nodeSelector` / tolerations to soft preferred affinity (prior soft-placement revision).
3. Keep critical STS pins if MNG remains healthy.
4. Do **not** downgrade Karpenter chart version from the application chart.

## Out of scope (follow-up)

* Hard zone `DoNotSchedule` once multi-AZ headroom is routine.
* MNG taints / PriorityClass / admission policy.
* Cluster Autoscaler for Critical MNG (scale-out is a reviewed Terraform `desired_size` change only).
* Descheduler for rebalancing already-running pods after new nodes appear.
