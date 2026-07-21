# Cluster-wide production acceptance

- Date: 2026-07-19
- Cluster: `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod`
- Promotion revision: `54d1a036bfc2562071e7c98f6e505aab1fcdd9c8`
- Overlay: `gitops/runtime-hardening/overlays/enforce-clusterwide`

## Live admission state

- `runtime-hardening` was Synced and Healthy; its last operation succeeded.
- Exactly three runtime-hardening policies were observed at current generation
  with zero non-null type-check warnings.
- Exactly three runtime-hardening bindings used only `[Deny]`.
- None of the three bindings contained a `namespaceSelector`.

Server-side dry-run admitted all approved or compliant system workloads:

- `DaemonSet/aws-node`
- `DaemonSet/kube-proxy`
- `DaemonSet/ebs-csi-node`
- `DaemonSet/ebs-csi-node-windows`
- `Deployment/ebs-csi-controller`
- `Deployment/coredns`
- `Deployment/cluster-autoscaler`

Native VAP denied invalid Pod, Deployment, and CronJob fixtures. It also denied
an unapproved `kube-system` Deployment near-miss and named
`runtime-hardening-pod-template.techx.io` plus its enforce binding in the
response. No test object was persisted.

## Inventory

The post-promotion literal inventory excluded no namespace and checked 218
workload objects and 330 containers. It remained at the approved baseline:

- 190 raw security-context findings;
- 33 objects and 33 groups;
- all findings map to the six signed exact system profiles;
- zero resource, image, or runtime-drift groups.

## Health and regression

- All four Argo CD Applications were Synced and Healthy at `54d1a03`.
- All 88 Pods were Running or Succeeded; no Running Pod was unready.
- flagd remained Running, 2/2 Ready, with zero restarts.
- Two email containers had historical OOM restart counts at approximately
  `06:05Z`, more than 35 minutes before the `06:40Z` admission promotion. Both
  were Ready and had no post-promotion restart.
- Storefront `/`: HTTP 200.
- `/grafana/`, `/jaeger/`, `/argocd/`, and `/feature`: HTTP 403.
- Ten post-promotion public product/cart/checkout transactions: 10/10 HTTP 200.

The first SLO sample overlapped the synthetic transaction burst and briefly
showed a frontend-proxy GET histogram spike. It had zero errors, did not persist,
and no workload rolled out. The clean five-minute server-span window passed for
all ten hot-path services with traffic, zero errors, and p95 below 1000ms; the
maximum observed p95 was 34.94ms.

## Result

MANDATE-05 runtime hardening is implemented and technically verified in
production. Enforcement is native Kubernetes admission, cluster-wide, and adds
no policy controller or Service. Storefront exposure, private operational
routes, and flagd behavior remain unchanged. Human signature rows in the ADR
remain independent governance records and are not inferred from this technical
verification.
