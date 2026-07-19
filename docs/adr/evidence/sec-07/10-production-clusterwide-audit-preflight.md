# Production cluster-wide audit preflight

- Date: 2026-07-19
- Cluster: `techx-tf2-prod`
- Git revision: `c8dbed86b52d5dbf1067163b7e768a99cb4f9a0a`
- Approval status: Pending Platform Security approval
- Cluster-wide Deny promotion: Not performed

## Procedure

The three existing migration-enforce bindings remained `[Deny]` with their
temporary system namespace selector. Three additional audit bindings were
created with `[Warn, Audit]` and no namespace selector, so system workload
profiles could be evaluated cluster-wide without blocking an update.

The live spec for each approved candidate was cleaned of server metadata and
submitted with server-side dry-run. An equivalent direct Pod was also submitted
with server-side dry-run. No object was persisted and no workload rolled out.

## Results

The workload template and Pod shape were both admitted for:

- `DaemonSet/aws-node`;
- `DaemonSet/kube-proxy`;
- `DaemonSet/ebs-csi-node`;
- `DaemonSet/ebs-csi-node-windows`;
- `Deployment/ebs-csi-controller`;
- `Deployment/coredns`.

All 12 dry-run requests completed with `VAP_WARNING_COUNT=0`. The deployed Pod
and pod-template policies were at observed generation `2/2` with no type-check
warnings.

## Cleanup and safety checks

The three temporary audit bindings were deleted immediately after the dry-run.
Only the three original `[Deny]` migration bindings remained, and no
`mandate5-preflight-*` Pod existed.

- All Argo CD Applications: Synced and Healthy.
- Storefront `/`: HTTP 200.
- `/grafana/`, `/jaeger/`, `/argocd/`, `/feature`: HTTP 403.
- flagd: both containers ready, zero restarts, Pod Running.

This preflight does not authorize cluster-wide Deny. Promotion remains blocked
until the owner and Platform Security approval rows in
`08-system-exception-approval-packet.md` are completed.
