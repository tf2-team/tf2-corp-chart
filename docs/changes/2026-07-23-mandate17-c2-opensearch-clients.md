# Mandate 17 C2 OpenSearch client remediation

## Problem

After the SEC-06 OpenSearch image was promoted, the service correctly exposed
HTTPS with basic authentication. Two client-side settings still blocked the
observability path:

- Grafana sent the internal `https://opensearch:9200` request through the
  external CONNECT proxy because the production `NO_PROXY` override omitted
  the short service name. Envoy returned 404 for that internal authority.
- The OTel exporter validated the demo certificate against the Kubernetes
  service name, while the certificate SAN contains `node-0.example.com` and
  `localhost`. Logs were dropped with an x509 hostname error.

## Change

- Add only `opensearch` to Grafana production `NO_PROXY` and `no_proxy`.
- Replace OTel `tls.insecure` with `tls.insecure_skip_verify: true`.

HTTPS and basic authentication remain enabled. NetworkPolicy and the Envoy
external-domain allowlist are unchanged.

## Verification

- `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml`
- `pwsh -NoProfile -File tests/mandate17/verify-rendered-manifests.ps1`
- `pwsh -NoProfile -File scripts/verify-runtime-hardening.ps1`
- `git diff --check`

After merge, wait for Argo `Synced/Healthy`, then require OTel logs without x509
export errors and Grafana OpenSearch datasource health HTTP 200.

## Rollback

Revert this commit through Git. Do not patch live Deployments or ConfigMaps.
