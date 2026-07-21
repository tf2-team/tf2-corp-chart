# System exception pre-approval test

- Date: 2026-07-19
- Source snapshot: `techx-tf2-prod`
- Test cluster: disposable Minikube, Kubernetes `v1.35.1`
- Production deployment: none
- Approval status: Pending Platform Security approval

The candidate Pod and pod-template policies were installed with the
`enforce-clusterwide` bindings only on the disposable cluster. All policies
reached their observed generation with zero type-check warnings.

## Admitted exact profiles

Both the workload template and equivalent direct Pod were admitted for:

- VPC CNI `DaemonSet/aws-node`;
- `DaemonSet/kube-proxy`;
- Linux and Windows EBS CSI node DaemonSets;
- `Deployment/ebs-csi-controller`;
- `Deployment/coredns`.

A CoreDNS ReplicaSet with controller owner `Deployment/coredns` was admitted.

## Denied near misses

Native VAP denied every tested near miss:

- wrong ReplicaSet controller owner;
- wrong service account;
- wrong stable vendor label;
- CoreDNS capability beyond `NET_BIND_SERVICE`;
- VPC CNI capability beyond `NET_ADMIN` and `NET_RAW`;
- `latest` image;
- missing CPU request and limit;
- additional unapproved container.

Each applicable case was tested for both a workload template and direct Pod.
Denial output named `ValidatingAdmissionPolicy`.

## Regression checks

- Helm lint: PASS.
- Negative values schema test: PASS.
- VAP base, audit, migration-enforce, and cluster-wide render contracts: PASS.
- EKS production API server dry-run of both modified policy resources: PASS;
  dry-run only, no production object was changed.

The implementation is review-ready but must not be selected by the production
Argo Application until the approval record in
`08-system-exception-approval-packet.md` is completed.
