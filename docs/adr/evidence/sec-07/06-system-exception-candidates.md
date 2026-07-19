# Cluster-wide system exception candidates

- Date: 2026-07-19
- Status: Pending Platform Security approval
- Scope: production `kube-system` workloads that require kernel or low-port
  privileges and cannot satisfy the generic non-root/drop-all rule.

These are candidate exceptions, not active policy exclusions. An exception may
be activated only after resource remediation is deployed, the full inventory is
rerun, and Platform Security signs the exact identity and rule set.

| Workload | Service account | Required exception | Reason | Owner | Expiry | Approval |
|---|---|---|---|---|---|---|
| `DaemonSet/aws-node` | `aws-node` | root/privileged and `NET_ADMIN`, `NET_RAW` | EKS VPC CNI configures host networking and network namespaces | Platform Engineering | 2026-10-17 | Pending |
| `DaemonSet/kube-proxy` | `kube-proxy` | root/privileged | Maintains host packet-routing rules | Platform Engineering | 2026-10-17 | Pending |
| `DaemonSet/ebs-csi-node` | `ebs-csi-node-sa` | root/privileged | Mounts block devices and registers the CSI node plugin on the host | Platform Engineering | 2026-10-17 | Pending |
| `DaemonSet/ebs-csi-node-windows` | `ebs-csi-node-sa` | OS-specific root/security-context exemption | EKS-managed Windows CSI node template | Platform Engineering | 2026-10-17 | Pending |
| `Deployment/ebs-csi-controller` | `ebs-csi-controller-sa` | EKS-managed security-context exemption | EKS add-on schema exposes resources but not per-container security contexts | Platform Engineering | 2026-10-17 | Pending |
| `Deployment/coredns` | `coredns` | `NET_BIND_SERVICE` and managed security-context exception | Binds DNS on port 53; current add-on schema exposes resources but not security context | Platform Engineering | 2026-10-17 | Pending |

Final policy matching must include namespace, workload identity, service account,
and stable vendor labels. It must not exclude all of `kube-system`. New workloads
or label/service-account drift must remain denied.
