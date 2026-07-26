# Mandate 17 containment rollout

## Safety contract

The code PR leaves production at `networkPolicy.enabled=false` and
`egressProxy.enabled=false`. Do not combine CNI activation, ingress isolation,
egress isolation, and chaos in one change window. Storefront exposure,
operational ingress, and the flagd source/provider contract are out of scope.

Current handoff baseline after Person 1 is chart `eaaf946`, frontend
`sha-ba6dd5b`, with Argo CD `Synced/Healthy`. Person 2 changes must be rebased
on that revision and must not change the frontend image or fallback contract.

## Traffic matrix

| Source | Destination | Port | Purpose |
|---|---|---:|---|
| Internal ALB subnets `10.0.10.0/24`, `10.0.11.0/24` | frontend-proxy | 8080 | Storefront target; verified from live ELBv2 subnet IDs |
| frontend-proxy | frontend and approved operator UIs | Service port | Routing |
| frontend | browse/cart/checkout dependencies | Declared gRPC port | Money path |
| checkout, accounting, fraud-detection | MSK in production VPC | 9092 | Durable events |
| cart, fraud-detection | Valkey in production VPC | 6379 | Cart/fraud state |
| product-catalog, product-reviews, accounting | PostgreSQL in production VPC | 5432 | Application data |
| first-party workloads | OTel collector | 4317/4318 | Telemetry |
| OTel collector | Jaeger, Prometheus, OpenSearch | 4317, 9090, 9200 | Trace/metric/log export |
| OTel collector, metrics-server | Kubernetes API/kubelets in VPC | 443, 10250 | Kubernetes attributes and resource metrics |
| Prometheus adapter, kube-state-metrics, inventory job | Kubernetes API | 443 | Metrics discovery and compliance inventory |
| Prometheus | kube-state-metrics, OTel, Karpenter | 8080/8081, 8888, 8080 | Scrape targets |
| all selected pods | CoreDNS in kube-system | UDP/TCP 53 | DNS only |
| approved callers | egress-proxy | 10000 | HTTPS CONNECT |
| egress-proxy | approved AWS/Groq hostnames | 443 | Allowlisted external API |
| flagd | `122.248.223.194/32` | 443 | Existing BTC HTTP provider |

No application pod receives direct `0.0.0.0/0`. The single internet CIDR rule
belongs to the proxy, whose virtual-host table limits CONNECT destinations.
Flagd is deliberately not proxy-injected.

Proxy and attacker images are pinned to immutable multi-architecture manifest
digests. Full enforcement is rejected by JSON Schema when the proxy digest is
missing.

## Pre-activation blockers

- Do not start C1 while CoreDNS replicas are co-located in one AZ/node; DNS is
  a money-path dependency for the AZ-loss test.
- Before C2, add the four proxy variables from
  `tests/mandate17/network-policy-values.yaml` under `grafana.env` in the
  activation values. Schema validation rejects full enforcement without them.
  The proxy allowlist covers the CUR datasource's Athena/Glue/STS/S3 endpoints
  in `ap-southeast-1` and the Discord contact point at `discord.com:443`.
  Prove both paths in the activation window; do not widen the proxy allowlist.
- Capture the positive traffic matrix and node headroom before activating the
  two proxy replicas. Do not compensate by widening an application rule.

## Rollout gates

### 1. Infra CNI controller

Apply the reviewed Infra plan while Chart policy is still disabled. Verify all
`aws-node` pods and the node agent are Ready, then verify the
`policyendpoints.networking.k8s.aws` CRD exists. No application traffic should
change at this gate.

### 2. Containment code, disabled

Merge the Chart code with the production values still set to false/false.
Argo CD must remain `Synced/Healthy`. Render tests and Mandate 5 verification
must pass.

Local verification from a clean checkout:

```powershell
helm dependency build .
helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml
./tests/mandate17/verify-rendered-manifests.ps1
./scripts/mandate17-inventory.ps1
./scripts/verify-directive-03.ps1
./scripts/verify-runtime-hardening.ps1
```

### 3. Ingress-only activation

Set `networkPolicy.enabled=true`, leave `enforceEgress=false`, and leave the
proxy disabled. This state renders no Egress policy or egress rule. Run the
positive traffic matrix and Locust for 10-15 minutes. Revert `enabled=false` on
any SLO, IRSA, telemetry, flagd, or Argo regression.

### 4. Full containment activation

Set `egressProxy.enabled=true` and `networkPolicy.enforceEgress=true` in one
reviewed revision. Copy the tested `grafana.env` proxy block into the
production activation overlay in the same revision. Wait for a healthy
PolicyEndpoint for every selected workload. Run positive flows first, then the
attacker test:

```powershell
$ctx = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
./scripts/mandate17-attacker-test.ps1 `
  -KubeContext $ctx `
  -RdsEndpoint "<rds-host>:5432" `
  -MskEndpoint "<broker-host>:9092" `
  -ValkeyEndpoint "<valkey-host>:6379"
```

DNS must pass. Same-namespace service, Kubernetes API, proxy, RDS, MSK,
Valkey, a cross-namespace operational service, and arbitrary internet attempts
must fail. The script requires a PolicyEndpoint for every NetworkPolicy and
coverage for every running pod, then waits until the attacker pod itself is in
PolicyEndpoint coverage before executing probes. It always removes its
Deployment and ServiceAccount.

For the Grafana positive gate, run one CUR dashboard query that reaches Athena
and S3, then send a dedicated test alert through the existing Discord contact
point. Record the Grafana query/alert timestamps and proxy access counters for
the same window. The in-cluster AIOps webhook remains covered by `NO_PROXY` and
must also continue to succeed.

## Rollback

Rollback in order: `true/true -> true/false -> false/false`. If the CNI node
agent itself is unhealthy, first disable Chart policy, then use the Infra
change record to remove the two CNI NetworkPolicy flags. Never rollback by
opening application egress to `0.0.0.0/0`, granting broad RBAC, or disabling
flagd.
