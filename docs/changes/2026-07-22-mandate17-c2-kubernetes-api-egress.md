# Mandate 17 C2 Kubernetes API egress remediation

## Incident

After C2 enabled namespace egress isolation, Grafana remained in init and the
runtime-hardening inventory Jobs timed out. Both workloads call the in-cluster
Kubernetes API, whose verified Service address is `172.20.0.1:443`.

Grafana had no API egress rule. Existing control-plane workload policies used
the production VPC CIDR (`10.0.0.0/16`) for TCP 443, which does not match the
Kubernetes Service ClusterIP.

## Change

- Define the Kubernetes API Service as the dedicated host CIDR
  `172.20.0.1/32`.
- Allow that CIDR on TCP 443 only for the approved API consumers: Grafana,
  runtime inventory, kube-state-metrics, metrics-server, Prometheus adapter,
  Prometheus and the OTel collector.
- Keep the VPC CIDR only where node/kubelet access on TCP 10250 is required.
- Add rendered-manifest regression checks for the exact API consumer matrix and
  reject VPC-wide API TCP 443 rules.

No application flow, RBAC, ServiceAccount, flagd, proxy allowlist or exposure
setting changes in this remediation.

## Validation

Run `helm lint`, the Mandate 17 rendered-manifest verifier and runtime-hardening
static verifier before merge. After Argo sync, require Grafana Ready with a
service endpoint, a new inventory Job Completed, all Argo applications Healthy
and a clean 15-minute SLO window before running the attacker matrix.

## Rollback

Revert this remediation. If C2 remains unhealthy, return production to C1 by
setting `networkPolicy.enforceEgress=false` and `egressProxy.enabled=false`
while leaving `networkPolicy.enabled=true`.
