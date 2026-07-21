# Final cluster-wide promotion gate

- Date: 2026-07-19
- Cluster: `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod`
- Gatekeeper source cleanup revision: `c66d423`
- Cluster Autoscaler hardening revision: `e840fee`

## Runtime state

- Gatekeeper Applications, AppProject, webhook, workloads, RBAC, custom
  resources, CRDs, and namespace are absent.
- All four remaining Argo CD Applications are Synced and Healthy.
- The three native VAP generations are observed with zero non-null type-check
  warnings; the migration bindings remain `[Deny]` until this promotion syncs.

## Inventory

The literal inventory excluded no namespace and checked 218 workload objects
and 330 containers. It reported 190 raw security-context findings across 33
objects and 33 groups, all belonging to the six exact `kube-system` profiles
approved by Trần Quốc Hùng:

- `DaemonSet/aws-node`
- `DaemonSet/kube-proxy`
- `DaemonSet/ebs-csi-node`
- `DaemonSet/ebs-csi-node-windows`
- `Deployment/ebs-csi-controller`
- `Deployment/coredns`

There were zero resource, image, or runtime-drift groups. The newly introduced
`Deployment/cluster-autoscaler` was remediated through Terraform with
`runAsNonRoot`, UID/GID 65534, RuntimeDefault seccomp, no privilege escalation,
read-only root filesystem, drop `ALL`, and complete CPU/memory requests and
limits. Its obsolete zero-replica ReplicaSet was deleted after revision 2 was
Ready.

## Admission preflight

A temporary cluster-wide `[Warn, Audit]` pod-template binding evaluated a
server-side dry-run of the live Cluster Autoscaler Deployment without a
runtime-hardening warning. The temporary binding was deleted immediately.

## Regression gates

- Storefront `/`: HTTP 200.
- `/grafana/`, `/jaeger/`, `/argocd/`, and `/feature`: HTTP 403.
- flagd: Running, both containers Ready, zero restarts.
- Ten public demo product/cart/checkout transactions: 10/10 HTTP 200.
- Five-minute server-span SLO: all ten hot-path services had traffic, zero
  errors, and p95 below 1000ms; the maximum observed p95 was 33.75ms.

The unfiltered service-level error query initially counted background
`flagd.evaluation.v1.Service/EventStream` client spans for `product-reviews`.
User-facing server spans had zero errors. The SLO query was scoped by
`span_kind="SPAN_KIND_SERVER"`; flagd was not disabled or modified.

## Promotion

This change selects `gitops/runtime-hardening/overlays/enforce-clusterwide`,
which renders exactly three `[Deny]` bindings and no `namespaceSelector`.
Post-merge acceptance must confirm that live state, repeat native denial and
inventory, and rerun Argo, route, flagd, and SLO checks.
