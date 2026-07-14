# Change: Ingress support for internal hostname HTTPS (ACM)

## Summary

Extended the storefront public Ingress so an optional **ACM certificate ARN** enables **HTTPS:443** on the internal ALB for operator private DNS (`https://internal.hungtran.id.vn`), while keeping **HTTP:80** for CloudFront VPC origin.

## Context

Infra requests ACM for `internal.hungtran.id.vn`. The ALB needs a certificate annotation and HTTPS listener. Path blocking and scheme stay as before.

## Before

* Ingress only set `listen-ports` from values (default HTTP:80).
* No certificate-arn annotation support.

## After

* When `publicAlb.certificateArn` is non-empty, Ingress sets:
  * `listen-ports: [{"HTTP":80},{"HTTPS":443}]`
  * `certificate-arn: <ARN>`
* When empty, behavior unchanged (HTTP only).
* **No** `ssl-redirect` (would break CloudFront origin).

## Technical Design Decisions

* Force dual ports only when cert is set — avoids controller errors from HTTPS without a cert.
* Leave host empty so CloudFront origin (ALB DNS Host header) still matches.

## Implementation Details

1. Updated `templates/frontend-proxy-public-ingress.yaml`.
2. Documented `certificateArn` in `values.yaml` / `values-public-alb.yaml` / `values-prod.yaml`.

## Files Changed

* `templates/frontend-proxy-public-ingress.yaml`
* `values.yaml`
* `values-public-alb.yaml`
* `values-prod.yaml`
* `docs/changes/2026-07-14-internal-hostname-https-acm.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-infra/docs/changes/2026-07-14-internal-hostname-https-acm.md`
* Requires ISSUED ACM ARN from infra before setting `certificateArn`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change until `certificateArn` is set |
| **Deployment** | Argo sync after ARN filled |
| **CloudFront** | Unchanged (HTTP:80 retained) |

## Validation

### Manual Verification

After ARN set and sync: on Client VPN, `curl -i https://internal.hungtran.id.vn/grafana/`

## Migration or Deployment Notes

1. Issue ACM cert for `internal.hungtran.id.vn` (ISSUED) outside Terraform.
2. Set the same ARN in infra `private_dns_acm_certificate_arn` and chart `values-prod.yaml` `publicAlb.certificateArn`.
3. Argo CD sync (or helm upgrade).

## Risks and Rollback

**Rollback:** clear `certificateArn` (and optional listenPorts override); ALB returns to HTTP-only.
