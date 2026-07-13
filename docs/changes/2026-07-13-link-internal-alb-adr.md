# Change: Link storefront ALB overlay to internal-ALB ADR

## Summary

Documented a pointer from `values-public-alb.yaml` to the infra ADR that explains why the storefront keeps an **internal ALB** as the CloudFront VPC origin (and why it is not a redundant public edge).

## Context

The rationale lives in `techx-corp-infra/docs/adr/storefront-edge-internal-alb.md`. Chart operators editing the public-alb overlay need a one-line link without duplicating the full ADR in this repo.

## Before

* `values-public-alb.yaml` described internal scheme and no path blocks, without a link to the decision record.

## After

* Header comment references `techx-corp-infra/docs/adr/storefront-edge-internal-alb.md`.

## Technical Design Decisions

* Comment-only link; ADR body stays in infra to avoid dual ownership of architecture text.

## Implementation Details

1. Added ADR path note at top of `values-public-alb.yaml`.

## Files Changed

* `values-public-alb.yaml` — ADR pointer in header comments.
* `docs/changes/2026-07-13-link-internal-alb-adr.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-infra/docs/adr/storefront-edge-internal-alb.md`
* Related: `techx-corp-infra/docs/changes/2026-07-13-adr-storefront-edge-internal-alb.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None |
| **Deployment** | None |
| **Backward compatibility** | Fully compatible |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A (comment-only) | — | N/A |

### Manual Verification

* Path in comment matches infra ADR location.

### Remaining Verification (Post-Merge)

* None.

## Migration or Deployment Notes

None.

## Risks and Rollback

None.

**Rollback procedure:** Remove the ADR comment lines from `values-public-alb.yaml`.
