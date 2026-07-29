# Mandate 21 FIS skip-all report

## Identity and revision bindings

- Run ID:
- AWS account / region:
- Cluster context:
- Chart Git SHA:
- Infra Git SHA:
- Contract SHA-256:
- Approval reference / approver / expiry:
- Infra preflight SHA-256:
- Capacity `1a-to-1b` SHA-256:
- Capacity `1b-to-1a` SHA-256:
- Audit evidence SHA-256 and complete evaluation window:

## Entry gates

| Gate | Required result | Evidence | Result |
|---|---|---|---|
| Infrastructure preflight | `PASS` | | |
| Capacity `1a-to-1b` | `PASS` | | |
| Capacity returned disabled | `PASS` | | |
| Capacity `1b-to-1a` | `PASS` | | |
| Capacity final state disabled | `PASS` | | |
| Three immutable-audit alarms | `OK` for full window | | |
| `CapacityApproved` | `PASS` | | |
| `ChangeApproved` | `PASS` | | |

## Four-template skip-all execution

| Order | Variant | Template ID | Revision SHA-256 / AWS timestamp | Experiment ID | Start / terminal UTC | Terminal state | Resolved target summary | Stop alarms | Cleanup |
|---:|---|---|---|---|---|---|---|---|---|
| 1 | `1a-primary-in` | | | | | | | | `NOT_APPLICABLE` |
| 2 | `1a-primary-outside` | | | | | | | | `NOT_APPLICABLE` |
| 3 | `1b-primary-in` | | | | | | | | `NOT_APPLICABLE` |
| 4 | `1b-primary-outside` | | | | | | | | `NOT_APPLICABLE` |

Aggregate result is `PASS` only when all four rows are present in this order, each FIS state is `completed`, and every cleanup value is `NOT_APPLICABLE`.

## Decision

- Aggregate result: `PASS` / `FAIL`
- Failed variant or gate:
- Remaining verification before any live fault:
- Approver signatures:

<!-- Change trail: @hungxqt - 2026-07-29 - Replaced the single-fault report with revision-bound four-template skip-all evidence. -->