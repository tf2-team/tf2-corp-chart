# Phase 3B system resource rollout proof

- Date: 2026-07-19
- Cluster: `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod`
- Infra merge: `202f715` (`fix(mandate-05): complete system workload resources`)
- Temporary capacity merge: `921d3b0` (`chore(): raise 1 temporary node`)

## Rollout

The production pipeline applied complete CPU and memory requests and limits to
VPC CNI, CoreDNS, kube-proxy, EBS CSI, and Karpenter. All four EKS managed
add-ons reported `ACTIVE`, all seven nodes reported Ready, and the affected
Deployments and DaemonSets reached their desired ready count.

AWS Load Balancer Controller chart `3.4.1` was upgraded separately with
`--wait --atomic --timeout 10m`. Revision 2 completed with two ready replicas.
The live controller container has:

- image `public.ecr.aws/eks/aws-load-balancer-controller:v3.4.1`;
- `runAsNonRoot: true`;
- capabilities `drop: [ALL]`;
- requests `50m` CPU and `128Mi` memory;
- limits `500m` CPU and `512Mi` memory.

Seven obsolete ReplicaSets were deleted only after each showed zero desired,
current, ready, and available replicas. Current Deployments remained fully
available throughout cleanup.

## Full-cluster inventory

| Checkpoint | Raw findings | Objects | Groups | Violating Pods | Runtime drift |
|---|---:|---:|---:|---:|---:|
| Initial baseline | 264 | 39 | 53 | 26 | 0 |
| First resource rollout | 237 | 41 | 49 | 26 | 2 |
| Follow-up rollout before old ReplicaSet cleanup | 228 | 43 | 43 | 27 | 8 |
| Final post-cleanup inventory | 190 | 33 | 33 | 25 | 0 |

The final inventory contains zero `RESOURCES` and zero `IMAGE_PIN` groups. All
remaining findings are security-context requirements of the exact EKS system
workloads documented in `06-system-exception-candidates.md`: VPC CNI,
kube-proxy, EBS CSI node/controller, and CoreDNS. Counts vary with DaemonSet
replica count; the root-owner group set is the stable review unit.

## Safety checks

- Storefront `/`: HTTP 200.
- `/grafana/`, `/jaeger/`, `/argocd/`, and `/feature`: HTTP 403.
- flagd: both containers ready, zero restarts, Pod Running.
- Argo CD: all Applications Synced and Healthy.
- Native VAP: three production bindings remain `[Deny]`.
- Gatekeeper remains enforcing until native cluster-wide promotion is approved
  and independently proved.

## Remaining gate

Platform Security must approve the six exact exception candidates, including
owner and expiry. The implementation must exempt only the necessary
security-context validation for the matching namespace, workload identity,
service account, and stable vendor labels. Image pinning and complete resources
must remain enforced for those workloads. A namespace-wide `kube-system`
exception is prohibited.
