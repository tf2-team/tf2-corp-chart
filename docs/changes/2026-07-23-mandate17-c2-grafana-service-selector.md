# Mandate 17 C2 Grafana Service-selector remediation

## Incident

PR #227 restored private Argo CD access, but the private Grafana route still
returned HTTP 503 while Grafana was Ready and its in-cluster health endpoint
returned 200.

The frontend-proxy egress policy selected Grafana with
`opentelemetry.io/name=grafana`, while the Grafana Service selects
`app.kubernetes.io/name=grafana`. AWS VPC CNI therefore compiled only the
Grafana pod IP on TCP 3000 and omitted the Service ClusterIP on TCP 80. Traffic
to `grafana:80` was denied before Service DNAT.

## Change

- Align the frontend-proxy destination selector with the Grafana Service:
  `app.kubernetes.io/name=grafana`.
- Keep the least-privilege pod target port TCP 3000.
- Add a rendered-manifest regression check that rejects the telemetry-label
  selector and Service port 80 for this rule.

No CIDR, workload, image, Service, ingress source, RBAC, ServiceAccount, flagd,
proxy allowlist or exposure setting changes.

## Validation

Run Helm lint and both Mandate 17/runtime-hardening verification workflows.
After Argo sync, the AWS PolicyEndpoint must contain Grafana Service ClusterIP
port 80 and Grafana pod IP port 3000. The private Grafana health route must
return 200 before continuing the Gate 4 positive matrix.

## Rollback

Revert this commit. If operational access or SLO becomes unhealthy, return to
C1 by disabling egress enforcement and the egress proxy while keeping ingress
containment enabled.
