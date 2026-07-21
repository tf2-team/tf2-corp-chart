# Workload Placement (Chart)

This chart implements **hard placement** between Critical MNG and Karpenter. Base/development values use soft topology balancing; the production overlay replaces it with hard zone and hostname spreading for the protected multi-replica workloads. Infrastructure capacity policy lives in `techx-corp-infra`.

## Placement contracts

| Contract | Mechanism | Workloads |
|----------|-----------|-----------|
| **Critical** | `nodeSelector.workload-class=critical`; no Karpenter toleration; singleton/stateful workloads opt out while protected production replicas may use hard spreads | `frontend-proxy`, `flagd`, `load-generator` master, stateful dependencies, Prometheus, Grafana, Jaeger, metrics-server, kube-state-metrics |
| **Stateless (default)** | `nodeSelector.workload-class=spot-tolerant` + matching `NoSchedule` toleration + preferred Spot affinity; soft zone spread and hard hostname spread | First-party Deployments inheriting `default.schedulingRules`; `load-generator-worker` intentionally packs and opts out of spread |
| **Universal DaemonSet** | No workload-class selector; Karpenter taint toleration | `opentelemetry-collector` (agent DaemonSet) |

### Important distinctions

* **`frontend`** is stateless → Karpenter.
* **`frontend-proxy`** is critical ingress/gateway → Critical MNG.
* Spot capacity-type affinity is a **preference only**. Primary vs On-Demand fallback is decided by **NodePool weight** in infra, not by chart affinity alone.
* Isolation is **one-way**: classified critical pods cannot land on Karpenter; classified stateless pods cannot land on MNG; **unclassified** pods without the Karpenter toleration can still schedule on MNG.
* Topology spread never replaces hard `nodeSelector` or tolerations. Production intentionally uses `DoNotSchedule` with `minDomains: 2`; loss of a schedulable AZ can therefore leave replicas Pending and requires operator action.

### Multi-replica HPA vs placement

| Service | HPA (base) | Contract | Note |
|---------|------------|----------|------|
| `frontend`, `checkout`, `cart`, `product-catalog`, `product-reviews`, `currency`, `recommendation` | production min **2–3** / max **6–72** (CPU + **RPS**, no memory metric); see `request-metric-hpa.md` | spot-tolerant | Karpenter can add nodes under scale-out; RPS is primary under traffic and CPU is the safety metric |
| `load-generator` | **none** (fixed 0–1 master) | critical | Locust **master** only on Critical MNG (`system-*`); scale to 1 for tests. Workers are `load-generator-worker` |
| `load-generator-worker` | **CPU-only HPA** (min 1, max 8; scaleDown 300s / 50%) | spot-tolerant + storefront anti-affinity + **preferred worker podAffinity (hostname pack)**; **no** topology spreads | Locust **workers** on Karpenter; prefer scale-out on one node first (cost); join master via `load-generator:5557`; stable scale-in to limit thrash |
| `frontend-proxy` | min **2** / max **10** (CPU 80% + **RPS**, no memory metric) | critical | Extra replicas **do not** land on Karpenter; Critical MNG must pass the headroom gate before load tests or maintenance |

Request-rate metrics require Prometheus Adapter (`prometheus-adapter.enabled`). See `docs/operations/request-metric-hpa.md`. Placement contracts are unchanged by metric type.

PDBs (`minAvailable: 1`) follow the active replica controller. When HPA is enabled,
only `autoscaling.minReplicas >= 2` is considered and a stale fixed `replicas` value
is ignored. Without HPA, fixed `replicas >= 2` renders the PDB. Production sets
`product-reviews.autoscaling.minReplicas: 2` explicitly.

Critical placement normally opts out of default stateless spreading. The
production overlay adds hard zone/hostname spreading to multi-replica critical
workloads such as `frontend-proxy`. `flagd` stays a **singleton** on Critical
MNG (`replicas: 1`, `workload-class=critical`, no topology spreads) so local
file/UI state is not split across emptyDirs.

## Pod distribution (topology spread)

Base/development defaults include:

| Constraint | `topologyKey` | `whenUnsatisfiable` | Purpose |
|------------|---------------|---------------------|---------|
| Zone | `topology.kubernetes.io/zone` | `ScheduleAnyway` | Prefer multi-AZ distribution of replicas |
| Node | `kubernetes.io/hostname` | `ScheduleAnyway` | Prefer not packing all replicas on one node |

* `labelSelector` is **template-injected** as `opentelemetry.io/name: <component>` (matches `techx-corp.selectorLabels`).
* Deployments also get `matchLabelKeys: [pod-template-hash]` so rolling updates do not skew against old ReplicaSet pods.
* Critical workloads **opt out** with `topologySpreadConstraints: []` to protect the small Critical MNG floor (`desired=1` per AZ).
* Soft spreads on single-replica Deployments are effectively a no-op.
* Production replaces both entries with `DoNotSchedule` and `minDomains: 2` for protected multi-replica workloads.

PriorityClass and Critical MNG taints remain separate follow-ups. Hard production spreading and active-controller **PDB** behavior are implemented.

## Template behavior

`templates/_objects.tpl` merges `default.schedulingRules` with per-component `schedulingRules`. When a component sets a key (`nodeSelector`, `affinity`, `tolerations`, or `topologySpreadConstraints`), that key **fully replaces** the default — including empty maps/lists so critical workloads clear Spot affinity, Karpenter tolerations, and default soft spreads.

## Overlays

* **values-dev.yaml** — base soft distribution and environment image/configuration values.
* **values-prod.yaml** — hard zone/hostname spreading, production replica floors, secrets, and critical kube-state-metrics placement.

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

```cmd
helm lint . -f values.yaml -f values-dev.yaml
helm template test . -f values.yaml -f values-dev.yaml > %TEMP%\render-dev.yaml
helm template test . -f values.yaml -f values-prod.yaml > %TEMP%\render-prod.yaml
```

Expected matrix (selected):

| Kind | Workload | Contract | Selector | Karpenter toleration | Topology spread |
|------|----------|----------|----------|----------------------|-----------------|
| Deployment | frontend | stateless | `spot-tolerant` | Yes | Production hard zone + hostname |
| Deployment | checkout | stateless | `spot-tolerant` | Yes | Production hard zone + hostname |
| Deployment | load-generator (master) | critical | `critical` | No | None (opt-out) |
| Deployment | load-generator-worker | stateless (pack-first) | `spot-tolerant` + storefront anti-affinity + preferred same-worker hostname affinity | Yes | None (opt-out; pack on one node first) |
| Deployment | frontend-proxy | critical | `critical` | No | Production hard zone + hostname |
| StatefulSet | postgresql / kafka / … | critical | `critical` | No | None (opt-out) |
| DaemonSet | otel-collector-agent | universal | none | Yes | N/A |
| Deployment | prometheus / grafana / jaeger / kube-state-metrics | critical | `critical` | No | N/A (subchart pins) |

List any intentionally unclassified workload explicitly during acceptance review.

## Live verification

```cmd
kubectl get nodes -L workload-class,topology.kubernetes.io/zone,karpenter.sh/capacity-type,role,karpenter.sh/nodepool
kubectl get pod -A -o wide

# Critical only on system-* (or labeled critical MNG during dual-run)
# Stateless only on Karpenter nodes (workload-class=spot-tolerant)
# OTel agent on both layers

# Multi-replica stateless distribution (when ≥2 eligible nodes/zones exist):
kubectl get pods -n %NAMESPACE% -l opentelemetry.io/name=frontend -o wide
kubectl get pods -n %NAMESPACE% -l opentelemetry.io/name=checkout -o wide
```

Zone spread prefers multi-zone placement but uses `ScheduleAnyway`, allowing recovery in one surviving AZ. Hostname spread uses `DoNotSchedule`, so replicas remain separated across eligible nodes.

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

* MNG taints / PriorityClass / admission policy.
* Cluster Autoscaler for Critical MNG (scale-out is a reviewed Terraform `desired_size` change only).
* Descheduler for rebalancing already-running pods after new nodes appear.

<!-- Change trail: @hungxqt - 2026-07-15 - Document active-controller PDBs and hard production topology spreading. -->
