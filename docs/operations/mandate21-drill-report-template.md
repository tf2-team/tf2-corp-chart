# Mandate 21 drill report

## Identity and revisions

- Fault ID:
- UTC baseline start:
- UTC FIS start/end:
- Randomly selected AZ:
- FIS experiment/template ID:
- RDS primary AZ before/after:
- Infra commit/Terraform plan:
- Platform commit/image:
- Chart commit/Argo revision:
- Operators:
- Reviewers:

## Entry gates

| Gate | Evidence | Result |
|---|---|---|
| Directive 20 sign-off | | |
| Audit alarms `OK` | | |
| Weekly forecast ≤ 300 USD | | |
| Same-AZ NAT routes | | |
| Single-AZ capacity | | |
| No Accounting errors for 30 min | | |
| No outbox item older than 60 sec | | |
| Argo Synced/Healthy and all Deployments Available | | |
| Required controllers/workloads span both AZs | | |
| External k6 and ledger active | | |

## Timeline and RTO

| UTC time | Event | Evidence |
|---|---|---|
| | Baseline began | |
| | FIS began | |
| | Rolling SLO first violated | |
| | ALB removed failed-AZ targets | |
| | RDS/Valkey transition | |
| | First recovered one-minute window | |
| | Third consecutive recovered window | |
| | FIS completed | |
| | Reconciliation completed | |

Measured RTO:

## SLO and durability result

| Acceptance | Observed | Result |
|---|---:|---|
| Browse success ≥ 99.5% | | |
| Cart success ≥ 99.5% | | |
| Checkout success ≥ 99% | | |
| Storefront p95 < 1 second | | |
| Dropped iterations = 0 | | |
| `charged = unique accepted = durable = persisted` | | |
| Duplicate order/charge = 0 | | |
| Unresolved ambiguous request = 0 | | |

## Cleanup

- Cleanup status: `PASS` / `FAIL` / `NOT_APPLICABLE`
- `cleanup-state.json` path:
- Failed checks (if any):
- FIS terminal state:
- FIS-managed NACL removed:
- Stopped instances recovered/replaced:
- No cordoned node:
- No Pending pod:
- Argo has no drift:
- Outbox has no stale item:
- Locust worker returned to zero/not used:

## Evidence index

- Wrapper preflight and snapshots:
- FIS log/timeline:
- Runtime cleanup state (`cleanup-state.json`):
- k6 raw summary and JSONL ledger:
- Person 2 reconciliation report:
- Dashboard export/screenshots:
- RDS/Valkey/DynamoDB/MSK API evidence:
- Cost and cleanup report:

## Decision

- Team result: `PASS` / `FAIL`
- Known limitations:
- Follow-up:
- Team signatures:
- Mentor/CDO review:

<!-- Change trail: @hungxqt - 2026-07-29 - Added cleanup status, failed checks, and cleanup-state.json path to drill report template. -->
