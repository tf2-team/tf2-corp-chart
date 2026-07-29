# Change: Promote Accounting orderitem Primary Key Refund Migration

## Summary

Promoted Accounting image digest and documented deployment rollout for `accounting.orderitem` primary key migration `(order_id, product_id, transaction_type)` executed via Helm PreSync hook.

## Context

Production Accounting service encountered repeated PostgreSQL 23505 duplicate key violations on `accounting.orderitem` during order cancellations. Upstream platform update added `orderitem` migration support to `--migrate-only`.

## Before

* Accounting PreSync migration job previously executed schema update that checked only `accounting.shipping`.
* `service-digest/values-accounting.yaml` referenced previous Accounting image build.

## After

* PreSync Helm hook automatically executes updated Accounting image in `--migrate-only` mode, widening `accounting.orderitem` primary key to `(order_id, product_id, transaction_type)`.
* Updated `service-digest/values-accounting.yaml` change trail format.

## Technical Design Decisions

* Utilized existing PreSync migration Job template to apply `orderitem` schema changes automatically prior to workload deployment.

## Implementation Details

1. Updated `service-digest/values-accounting.yaml` change trail comment positioning.
2. Created promotion change documentation record.

## Files Changed

* `service-digest/values-accounting.yaml` — Updated change trail.
* `docs/changes/2026-07-29-promote-accounting-orderitem-refund-migration.md` — Chart promotion change record.

## Dependencies and Cross-Repository Impact

* `techx-corp-platform`: Requires Accounting image with updated `DatabaseMigrator.cs`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Resolves 23505 errors on order cancellations in production |
| **Infrastructure** | No infrastructure changes |
| **Deployment** | PreSync job applies database migration cleanly before pod rollout |
| **Performance** | Eliminates consumer retry loop overhead |
| **Security** | No change |
| **Reliability** | Ensures order cancellation processing succeeds |
| **Cost** | No change |
| **Backward compatibility** | Fully backward compatible |
| **Observability** | Eliminates repeated orderitem_pkey error logs |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm Lint | `helm lint .` | ✅ Pass |

## Migration or Deployment Notes

Argo CD auto-sync executes PreSync migration job before updating Accounting deployment.

## Risks and Rollback

**Rollback procedure:**
Revert digest promotion commit in `techx-corp-chart`. Do not shrink primary key in database.

# Change trail: @hungxqt - 2026-07-29 - Promote Accounting orderitem refund primary key migration.
