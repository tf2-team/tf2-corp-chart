# Change: Internal storefront ALB without path-block rules

## Summary

Changed the storefront Ingress (`frontend-proxy-public`) from an **internet-facing** ALB with optional fixed-response path blocks to an **internal** ALB that forwards all paths to `frontend-proxy`. Public access and sensitive-path 403s move to **CloudFront** (VPC origin + Function) in `techx-corp-infra`.

## Context

Path blocking on the public ALB was the previous storefront security posture. With CloudFront in front of the ALB via VPC origin, the ALB must not be internet-facing, and edge path policy belongs at CloudFront so the private ALB does not need listener 403 rules.

* Why now: align chart with infra CloudFront VPC origin cutover.
* Related infra: `techx-corp-infra/docs/changes/2026-07-13-internal-alb-cloudfront-vpc-origin.md`

## Before

* Default / prod: `scheme: internet-facing`, `blockSensitivePaths: true` (ALB 403 for admin prefixes).
* `values-public-alb.yaml` enabled public ALB; prod overlay kept blocking on.
* Ingress template defaulted missing `blockSensitivePaths` to **true** (secure public default).
* Smoke test treated `-a` as public ALB HTTP host for 403 checks.

## After

* Defaults and overlays: `scheme: internal`, `blockSensitivePaths: false`.
* Ingress template defaults missing `blockSensitivePaths` to **false**; scheme defaults to `internal`.
* Optional emergency ALB blocks still supported if `blockSensitivePaths: true`.
* Smoke test `-a` expects **HTTPS edge** (CloudFront alias) for path-block verification.

## Technical Design Decisions

* **Keep resource name `frontend-proxy-public`:** Avoids renaming Ingress/GitOps references; “public” means storefront entry Ingress, not internet-facing scheme.
* **No ALB blocks by default:** Matches CloudFront-owned path policy; reduces duplicate 403 sources.
* **Retain blockedPrefixes + template support:** Break-glass without CloudFront.

## Implementation Details

1. Updated `values.yaml` publicAlb defaults to internal / no blocks.
2. Updated `values-public-alb.yaml`, `values-dev.yaml`, `values-prod.yaml`.
3. Adjusted Ingress template comments and default block flag.
4. Updated `scripts/smoke-test.sh` edge-check messaging and default scheme to https for `-a`.

## Files Changed

**Configuration:**

* `values.yaml` — publicAlb scheme internal; blockSensitivePaths false.
* `values-public-alb.yaml` — enable internal ALB; no path blocks.
* `values-dev.yaml` / `values-prod.yaml` — scheme internal; blockSensitivePaths false.

**Templates:**

* `templates/frontend-proxy-public-ingress.yaml` — defaults for internal / no blocks; comments.

**Scripts / docs:**

* `scripts/smoke-test.sh` — edge (CloudFront) path-block checks.
* `docs/changes/2026-07-13-internal-alb-no-path-blocks.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Requires** infra CloudFront VPC origin + path blocking for production edge posture.
* Related: `techx-corp-infra/docs/changes/2026-07-13-internal-alb-cloudfront-vpc-origin.md`
* After scheme flip, operators must update Terraform `cloudfront_origin_domain_name` and `cloudfront_origin_alb_arn` (ALB recreate).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Storefront still via frontend-proxy; public clients should use CloudFront |
| **Infrastructure** | ALB becomes internal (likely recreate); needs private subnet internal-elb tags |
| **Deployment** | Argo sync of values; possible Ingress delete+recreate for scheme change |
| **Security** | ALB not internet-facing; rely on CloudFront for public path policy |
| **Reliability** | Brief disruption while ALB recreates and CloudFront origin updates |
| **Backward compatibility** | Direct public-ALB URL access ends after cutover |
| **Observability** | No change to app metrics |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | ✅ Pass |
| Helm template | `helm template … -f values-public-alb.yaml -f values-prod.yaml` | ✅ scheme=internal; path only `/` |

### Manual Verification

* Rendered Ingress: annotation `alb.ingress.kubernetes.io/scheme: "internal"`.
* Paths: only `/` → frontend-proxy when blockSensitivePaths false.

### Remaining Verification (Post-Merge)

* Cluster: Ingress address present; ALB scheme internal in EC2 console.
* Edge: CloudFront 403 on blocked prefixes (infra apply).

## Migration or Deployment Notes

1. Merge/sync this chart change with infra CloudFront VPC origin change.
2. If scheme does not update in place:

```cmd
kubectl delete ingress frontend-proxy-public -n techx-corp
```

Then re-sync Argo / re-apply Helm.

3. Collect new ALB DNS/ARN for infra tfvars.
4. Do not rely on ALB DNS for public smoke tests; use CloudFront alias with `-a`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Scheme in-place update fails | Medium | Medium | Delete Ingress; re-sync |
| CloudFront not updated after ALB recreate | Medium | High | Documented cutover; keep CF apply in same window |
| Temporary open admin paths if CF block off | Low | Medium | Prod `cloudfront_block_sensitive_paths=true` |

**Rollback procedure:**

1. Set `scheme: internet-facing` and optional `blockSensitivePaths: true` in values; re-sync (may recreate ALB).
2. Point clients at ALB or restore prior CloudFront custom origin config in infra if required.
