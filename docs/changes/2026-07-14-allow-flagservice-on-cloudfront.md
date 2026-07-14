# Change: Align chart docs with CloudFront `/flagservice` allow

## Summary

Updated chart comments and emergency ALB block-prefix list so `/flagservice` is not treated as a blocked admin path. Public flagd evaluation is allowed at CloudFront (infra change).

## Context

Infra removed `/flagservice` from the CloudFront Function block list so browser EventStream works. Chart lists/comments needed the same policy.

## Before

* Comments listed `/flagservice` among CF-blocked prefixes.
* Emergency ALB `blockedPrefixes` included `/flagservice`.

## After

* Comments state `/flagservice` (and `/otlp-http`) are allowed for browser use.
* Emergency ALB list no longer includes `/flagservice`.

## Technical Design Decisions

* Chart does not own CloudFront Function code; documentation + emergency list alignment only.
* `/feature` (flagd UI) remains on emergency block list.

## Implementation Details

1. Updated `values-public-alb.yaml` and `values.yaml` `blockedPrefixes`.
2. Updated `docs/DEPLOYMENT.md`.

## Files Changed

* `values.yaml`
* `values-public-alb.yaml`
* `docs/DEPLOYMENT.md`
* `docs/changes/2026-07-14-allow-flagservice-on-cloudfront.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-infra/docs/changes/2026-07-14-allow-flagservice-on-cloudfront.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change unless emergency ALB path blocks enabled |
| **Deployment** | Docs/values only; live CF fix needs infra apply |

## Validation

None for chart-only alignment.

## Migration or Deployment Notes

Apply **infra** production Terraform for live CloudFront behavior.

## Risks and Rollback

**Rollback:** restore `/flagservice` in chart emergency list/comments if needed.
