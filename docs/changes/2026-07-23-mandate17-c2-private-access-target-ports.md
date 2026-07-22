# Mandate 17 C2 private access target-port remediation

## Incident

After the Kubernetes API egress remediation, Grafana and Argo CD were healthy
inside the cluster, but the private routes `/grafana/` and `/argocd/` returned
HTTP 503 through the frontend proxy.

AWS VPC CNI compiled the frontend-proxy egress selectors to destination pod
IPs. The policy allowed the Service port 80, while kube-proxy DNAT sends the
traffic to Grafana container port 3000 and Argo CD server port 8080.

## Change

- Allow frontend-proxy to reach Grafana pods only on TCP 3000.
- Allow frontend-proxy to reach Argo CD server pods only on TCP 8080.
- Add rendered-manifest regression checks that reject Service port 80 for both
  selector rules.

No CIDR, ingress source, application, image, Service, RBAC, ServiceAccount,
flagd, proxy allowlist or public/private exposure setting changes.

## Validation

Run Helm lint and the Mandate 17/runtime-hardening verifiers before merge. After
Argo sync, require both PolicyEndpoint rules to use the pod target ports, verify
the private Grafana health route returns 200 and the Argo CD route no longer
returns 503, then continue the Gate 4 positive matrix.

## Rollback

Revert this commit. If private operational access or SLO remains unhealthy,
return production to C1 by setting `networkPolicy.enforceEgress=false` and
`egressProxy.enabled=false` while keeping `networkPolicy.enabled=true`.
