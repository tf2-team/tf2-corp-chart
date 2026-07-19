# System exception approval packet

- Date: 2026-07-19
- Cluster: `techx-tf2-prod`
- Requested owner: Platform Engineering
- Requested approver: Platform Security
- Proposed expiry: 2026-10-17
- Status: Approved; cluster-wide promotion pending

## Invariants

Every exception requires namespace `kube-system`, the exact workload identity,
the exact service account, stable vendor labels, and the expected container
name. Pod admission must use the equivalent service-account, label, and
container identity because generated Pods do not carry the parent workload name
as their own name.

No exception may bypass fixed-image validation or CPU/memory requests and
limits. Ephemeral containers remain fully restricted. A new workload, wrong
service account, missing label, extra container, or broader capability set must
remain denied.

## Requested rule scope

| Workload/container | Service account | Stable labels | Security validations requested for exception |
|---|---|---|---|
| `DaemonSet/aws-node` / `aws-node` | `aws-node` | `app.kubernetes.io/instance=aws-vpc-cni`, `app.kubernetes.io/name=aws-node`, `k8s-app=aws-node` | Explicit non-root; drop `ALL`; allow only the vendor `NET_ADMIN` and `NET_RAW` additions |
| `DaemonSet/aws-node` / `aws-eks-nodeagent` | `aws-node` | same as above | Explicit non-root; drop `ALL`; allow only vendor `NET_ADMIN` behavior |
| `DaemonSet/aws-node` / init `aws-vpc-cni-init` | `aws-node` | same as above | Explicit non-root and drop `ALL` |
| `DaemonSet/kube-proxy` / `kube-proxy` | `kube-proxy` | `k8s-app=kube-proxy` | Explicit non-root and drop `ALL` |
| `DaemonSet/ebs-csi-node` / `ebs-plugin`, `node-driver-registrar`, `liveness-probe` | `ebs-csi-node-sa` | `app=ebs-csi-node`, `app.kubernetes.io/component=csi-driver`, `app.kubernetes.io/managed-by=EKS`, `app.kubernetes.io/name=aws-ebs-csi-driver` | Explicit non-root, UID 0, and drop `ALL` |
| `DaemonSet/ebs-csi-node-windows` / same three container names | `ebs-csi-node-sa` | same as above | Explicit non-root and drop `ALL`; valid only for the Windows workload identity |
| `Deployment/ebs-csi-controller` / all six declared sidecars | `ebs-csi-controller-sa` | `app=ebs-csi-controller`, `app.kubernetes.io/component=csi-driver`, `app.kubernetes.io/managed-by=EKS`, `app.kubernetes.io/name=aws-ebs-csi-driver` | Drop `ALL` only |
| `Deployment/coredns` / `coredns` | `coredns` | `eks.amazonaws.com/component=coredns`, `k8s-app=kube-dns` | Explicit non-root; allow only `NET_BIND_SERVICE` while retaining drop `ALL` |

The EBS CSI controller container set is `ebs-plugin`, `csi-provisioner`,
`csi-attacher`, `csi-snapshotter`, `csi-resizer`, and `liveness-probe`. Any
additional container is outside the requested exception.

## Required tests before activation

1. Each exact system fixture is admitted by the cluster-wide policy.
2. The same fixture in another namespace is denied.
3. Wrong workload name, service account, or stable label is denied.
4. An additional or renamed container is denied.
5. `latest`, untagged image, or malformed digest is denied for an approved
   system workload.
6. Missing CPU or memory request/limit is denied for an approved system
   workload.
7. CoreDNS adding any capability other than `NET_BIND_SERVICE` is denied.
8. VPC CNI adding a capability outside its approved set is denied.
9. Ephemeral containers that violate generic hardening are denied.
10. Native VAP denial output names the native policy while Gatekeeper is in
    `dryrun`, followed by restoration of Gatekeeper to `deny`.

## Approval record

| Role | Name | Decision | Date | Notes |
|---|---|---|---|---|
| Platform Engineering owner | Trần Quốc Hùng | Approved | 2026-07-19 | Approved the exact workload, container, identity, and expiry scope in this packet |
| Platform Security approver | Trần Quốc Hùng | Approved | 2026-07-19 | Approved for controlled cluster-wide enforcement after the recorded audit preflight |
