# Mandate 21 Infrastructure Preflight Report

**Collected At:** 2026-07-29T13:25:10.1915846Z
**Region:** us-east-1
**Overall Status:** PASS

## Validation Summary

| Check | Status |
|---|---|
| Private subnet subnet-07599236e4979c4b2 in us-east-1a has available NAT Gateway in same AZ | PASS |
| Private subnet subnet-0ee04e7bc69e247a3 in us-east-1b has available NAT Gateway in same AZ | PASS |
| Private subnet subnet-0d1f0d1de6b352021 in us-east-1a has available NAT Gateway in same AZ | PASS |
| Private subnet subnet-0ab17749536b34693 in us-east-1b has available NAT Gateway in same AZ | PASS |
| RDS techx-prod-tf2-postgresql is available | PASS |
| RDS techx-prod-tf2-postgresql is Multi-AZ | PASS |
| RDS techx-prod-tf2-postgresql storage encryption is enabled | PASS |
| RDS techx-prod-tf2-postgresql deletion protection is enabled | PASS |
| RDS techx-prod-tf2-postgresql backup retention is >=7 days | PASS |
| Valkey techx-prod-tf2-cart status is available | PASS |
| Valkey techx-prod-tf2-cart automatic failover is enabled | PASS |
| Valkey techx-prod-tf2-cart at-rest encryption is enabled | PASS |
| Valkey techx-prod-tf2-cart transit encryption is enabled | PASS |
| DynamoDB table techx-prod-tf2-checkout-outbox status is ACTIVE | PASS |
| DynamoDB table techx-prod-tf2-checkout-outbox deletion protection is enabled | PASS |
| DynamoDB table techx-prod-tf2-checkout-outbox PITR is ENABLED | PASS |
| MSK cluster techx-prod-tf2-msk status is ACTIVE | PASS |
| MSK cluster techx-prod-tf2-msk has >=2 broker nodes across AZs | PASS |

<!-- Change trail: @hungxqt - 2026-07-29 - Generated fail-closed infrastructure preflight summary report. -->
