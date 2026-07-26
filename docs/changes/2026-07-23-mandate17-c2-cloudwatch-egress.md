# Change: Allow scoped Grafana CloudWatch egress

## Summary

Add the two exact regional AWS endpoints used by the provisioned Grafana
CloudWatch datasource to the Mandate 17 HTTPS CONNECT proxy allowlist:

- `monitoring.us-east-1.amazonaws.com:443`
- `logs.us-east-1.amazonaws.com:443`

No CIDR, wildcard AWS domain, NetworkPolicy selector, datasource credential, or
Grafana authentication setting changes.

## Evidence and rationale

With C2 egress enforcement active, Grafana datasource health returned HTTP 400.
Both CloudWatch SDK calls failed at the proxy with `CONNECT tunnel failed,
response 404`. The live Envoy configuration did not contain either requested
CONNECT authority. Other scoped Grafana routes remained functional.

The fix extends the existing proxy allowlist with only the two observed regional
destinations. Grafana continues to reach the proxy on its existing policy rule;
the proxy continues to deny every destination not explicitly listed.

## Validation

- `helm lint . -f values-prod.yaml`
- `tests/mandate17/verify-rendered-manifests.ps1`
- `scripts/verify-runtime-hardening.ps1`
- Post-sync: Grafana CloudWatch datasource health must return HTTP 200 / `OK`.

## Rollback

Revert these two allowlist entries. Envoy rolls automatically because the proxy
Deployment checksum includes its ConfigMap content.

<!-- Change trail: @MinhKhoa2209 - 2026-07-23 - Allow exact CloudWatch metrics/logs endpoints for Mandate 17 C2. -->
