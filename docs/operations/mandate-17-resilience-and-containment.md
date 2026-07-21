# Mandate 17 containment rollout

## Safety contract

The code PR leaves production at `networkPolicy.enabled=false` and
`egressProxy.enabled=false`. Do not combine CNI activation, ingress isolation,
egress isolation, and chaos in one change window. Storefront exposure,
operational ingress, and the flagd source/provider contract are out of scope.

## Traffic matrix

| Source | Destination | Port | Purpose |
|---|---|---:|---|
| ALB addresses in production VPC | frontend-proxy | 8080 | Public storefront target |
| frontend-proxy | frontend and approved operator UIs | Service port | Routing |
| frontend | browse/cart/checkout dependencies | Declared gRPC port | Money path |
| checkout, accounting, fraud-detection | MSK in production VPC | 9092 | Durable events |
| cart, fraud-detection | Valkey in production VPC | 6379 | Cart/fraud state |
| product-catalog, product-reviews, accounting | PostgreSQL in production VPC | 5432 | Application data |
| first-party workloads | OTel collector | 4317/4318 | Telemetry |
| all selected pods | CoreDNS in kube-system | UDP/TCP 53 | DNS only |
| approved callers | egress-proxy | 10000 | HTTPS CONNECT |
| egress-proxy | approved AWS/Groq hostnames | 443 | Allowlisted external API |
| flagd | `122.248.223.194/32` | 443 | Existing BTC HTTP provider |

No application pod receives direct `0.0.0.0/0`. The single internet CIDR rule
belongs to the proxy, whose virtual-host table limits CONNECT destinations.
Flagd is deliberately not proxy-injected.

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

### 3. Ingress-only activation

Set `networkPolicy.enabled=true`, leave `enforceEgress=false`, and leave the
proxy disabled. This state renders no Egress policy or egress rule. Run the
positive traffic matrix and Locust for 10-15 minutes. Revert `enabled=false` on
any SLO, IRSA, telemetry, flagd, or Argo regression.

### 4. Full containment activation

Set `egressProxy.enabled=true` and `networkPolicy.enforceEgress=true` in one
reviewed revision. Wait for a healthy PolicyEndpoint for every selected
workload. Run positive flows first, then the attacker test:

```powershell
$ctx = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
./scripts/mandate17-attacker-test.ps1 `
  -KubeContext $ctx `
  -RdsEndpoint "<rds-host>:5432" `
  -MskEndpoint "<broker-host>:9092" `
  -ValkeyEndpoint "<valkey-host>:6379"
```

DNS must pass. Same-namespace service, Kubernetes API, proxy, RDS, MSK,
Valkey, and arbitrary internet attempts must fail. The script always removes
its Deployment and ServiceAccount.

## Rollback

Rollback in order: `true/true -> true/false -> false/false`. If the CNI node
agent itself is unhealthy, first disable Chart policy, then use the Infra
change record to remove the two CNI NetworkPolicy flags. Never rollback by
opening application egress to `0.0.0.0/0`, granting broad RBAC, or disabling
flagd.
