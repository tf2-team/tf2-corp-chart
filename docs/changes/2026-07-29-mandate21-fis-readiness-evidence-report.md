# Change: Add Mandate 21 FIS Readiness Evidence Report

## Summary

Adds a live, read-only Mandate 21 evidence report covering the four AWS FIS
templates, target selectors, stop alarms, skip-all and cleanup state, zonal
Route/NAT topology, Karpenter capacity, managed stores, cost and change gates,
and the immutable-audit evaluation window. The report records the current
overall decision as `NO-GO / FAIL` because several mandatory gates are not
satisfied.

## Context

The Mandate 21 FIS execution decision requires one consolidated evidence pack.
Repository documentation previously described pending or historical state, but
the live account changed on 2026-07-29: four new templates now exist while the
checked-in runtime contract still references obsolete IDs. A fresh report was
needed to separate passing infrastructure components from unresolved runtime,
approval, cost, capacity, and audit gates.

## Before

There was no 2026-07-29 consolidated report that tied the current live
template IDs and revisions to their selectors, stop alarms, experiment
history, cleanup state, infrastructure state, approvals, and audit alarms.
The runtime contract referenced four IDs that no longer exist.

## After

`docs/evidence/mandate-21/2026-07-29/fis-readiness-evidence-report.md`
contains the complete read-only capture and a fail-closed decision. It records:

- the four live FIS IDs, update timestamps, deterministic revision hashes,
  selectors, actions, stop-alarm ARNs, and cleanup policy;
- the absence of skip-all experiments and cleanup-state artifacts;
- same-AZ Route/NAT evidence and managed-store health;
- current Karpenter state and the missing controlled capacity probe;
- the `393.779034 USD` drill-week forecast;
- missing capacity/change approval evidence; and
- two failing immutable-audit alarms.

## Technical Design Decisions

The report uses live service APIs as the authority for mutable operational
state and the checked-out scripts as the authority for the expected execution
contract. It does not infer `PASS` from configuration alone. Template revisions
are represented by AWS `lastUpdateTime` plus SHA-256 over recursively
key-sorted compact template JSON. No FIS preview was started because
`start-experiment`, including `skip-all`, changes AWS state and was outside the
approved read-only scope.

## Implementation Details

1. Inspected the current contract, execution wrapper, preflight collector,
   capacity runner, cleanup module, and runbook.
2. Queried the AWS account for FIS, VPC, NAT, RDS, ElastiCache, DynamoDB, MSK,
   Cost Explorer, and CloudWatch state.
3. Queried the production EKS cluster read-only for nodes, NodeClaims,
   NodePools, Karpenter health, Pending pods, scheduling events, and the
   capacity-probe Deployment.
4. Calculated live FIS revision hashes and the seven-day cost forecast.
5. Recorded every requested gate with evidence-backed `PASS`, `FAIL`, or
   `PENDING` status.

## Files Changed

**Documentation:**

* `docs/evidence/mandate-21/2026-07-29/fis-readiness-evidence-report.md` —
  Consolidated live readiness report.
* `docs/changes/2026-07-29-mandate21-fis-readiness-evidence-report.md` — This
  change record.

## Dependencies and Cross-Repository Impact

No files in `techx-corp-infra` or `techx-corp-platform` were modified. Follow-up
remediation will require coordination with infrastructure ownership for the
FIS contract, collector defaults, audit controls, and cost gate, but those
changes are not implemented by this documentation change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change. |
| **Infrastructure** | No infrastructure change; read-only evidence only. |
| **Deployment** | No deployment. The report blocks FIS execution until all gates pass. |
| **Performance** | No change. |
| **Security** | Preserves fail-closed gates and does not expose credentials or secret payloads. |
| **Reliability** | Makes unresolved capacity, audit, and cleanup evidence explicit. |
| **Cost** | Records a `393.779034 USD/7 days` forecast, `93.779034 USD` above the gate. |
| **Backward compatibility** | Documentation-only and backward-compatible. |
| **Observability** | Consolidates CloudWatch alarm and metric-window evidence. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Live AWS inventory | AWS CLI read-only APIs | Pass; requested resources and failure states captured |
| EKS/Karpenter inventory | `kubectl get` read-only queries | Pass; current state captured |
| Template revision hashing | PowerShell SHA-256 over key-sorted JSON | Pass; four hashes produced |
| Cost calculation | PowerShell arithmetic over Cost Explorer response | Pass; `393.779034 USD` forecast |

### Manual Verification

* Compared checked-in FIS IDs with live template inventory.
* Verified each template selector and all four stop-alarm ARNs.
* Verified the FIS experiment list was empty.
* Verified there was no capacity-probe Deployment or approval artifact.
* Verified every report section uses observed status rather than intended
  status.

### Remaining Verification (Post-Merge)

Regenerate the report after remediation, approval, two-direction capacity
testing, and four separately approved `skip-all` previews.

## Migration or Deployment Notes

None. This change is documentation-only.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Live evidence becomes stale | High | Medium | Timestamp the capture and rerun all read-only checks before any change window. |
| Operators treat component PASS as overall approval | Low | High | The report leads with `NO-GO / FAIL` and records each approval separately. |

**Rollback procedure:**

Revert the documentation commit if the evidence report must be withdrawn:

```cmd
git revert <commit>
```

<!-- Change trail: @hungxqt - 2026-07-29 - Documented the addition and validation of the live Mandate 21 FIS readiness evidence report. -->
