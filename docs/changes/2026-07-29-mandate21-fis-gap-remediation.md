# Change: Remediate Mandate 21 FIS Readiness Gaps

## Summary

Adds fail-closed infrastructure and capacity evidence, synchronizes the four current FIS templates to canonical expected revisions, replaces synthetic preview behavior with a strictly approved four-template `skip-all` orchestration path, and removes cost approval from the active gate. Production capacity remains disabled and no FIS experiment was started by this change.

## Context

The 2026-07-29 readiness capture found obsolete template IDs, no real skip-all history, stale managed-store defaults, no controlled surviving-AZ capacity proof, no revision-bound approval artifact, and immutable-audit alarms blocked by historical DLQ backlogs. The implementation closes the repository gaps while retaining separate approval boundaries for GitOps changes, DLQ deletion, tests, and AWS FIS execution.

## Before

The contract referenced four deleted templates. The wrapper treated `skip-all` as a synthetic local branch, allowed switch/token approval fallbacks, and selected one random live variant. Infrastructure preflight selected a non-default VPC rather than the EKS VPC and used stale Valkey/MSK names. Capacity proof accepted existing NodeClaims and did not prove a full soak. The active workflow included a cost-approval switch.

## After

The contract binds four live IDs to canonical full-template SHA-256 revisions and exact stop alarms. Strict approval JSON binds account, cluster, chart/infra SHAs, evidence hashes, four template revisions, `CapacityApproved`, and `ChangeApproved` for no more than 24 hours. Real skip-all execution is fixed-order, sequential, fail-fast, and atomically records partial evidence. Preflight derives the VPC from EKS, validates same-AZ NAT routes and all stores, while capacity proof requires new surviving-AZ NodeClaims, probe attribution, and eleven samples over five minutes. The resting production overlay remains disabled.

## Technical Design Decisions

Canonical hashes cover complete FIS template objects, so selector, action, alarm, and option drift is rejected. AWS and kubectl calls use argument arrays; no shell evaluation or direct Kubernetes/Helm mutation is introduced. Capacity baseline and deployed revisions are separate because a Git commit cannot embed its own future SHA. Skip-all cleanup is `NOT_APPLICABLE`, and the wrapper never issues cleanup mutations. Cost approval is intentionally not part of the active approval schema.

## Implementation Details

1. Added pure preflight/capacity evaluators, EKS-derived collection, GitOps configuration generation, and read-only soak measurement.
2. Added a secure, traceable capacity Deployment and resting disabled overlay loaded last by Argo.
3. Added canonical contract hashing, live verification, authoritative hashes/alarms, and current template IDs.
4. Added exact-field approval validation, JSON schema/examples, evidence hashing, alarm-window checks, and expiration.
5. Added injectable fixed-order FIS orchestration and atomic pre-start/transition/failure evidence envelopes.
6. Added fixture/mocked tests and updated operator/report/evidence documentation.

## Files Changed

**Capacity and preflight:**
* `scripts/mandate21-evidence.psm1` — Pure fail-closed evaluators.
* `scripts/collect-infra-preflight.ps1` — EKS-derived network/store evidence.
* `scripts/run-capacity-probe.ps1` — GitOps generator and read-only soak measurement.
* `templates/capacity-probe.yaml` — Hardened revision-bound probe.
* `values.yaml` — Base capacity traceability fields.
* `values-capacity-probe.yaml` — Resting disabled production overlay.
* `gitops/clusters/prod/application.yaml` — Loads the resting overlay last.
* `values.schema.json` — Strict schema for the new capacity fields.
* `tests/mandate21/verify-capacity-preflight.ps1` — Negative and soak fixtures.

**FIS contract and approval:**
* `scripts/mandate21-fis-contract.json` — Current four IDs, expected hashes, account, alarms, and cleanup mapping.
* `scripts/mandate21-fis-contract.example.json` — Schema-current validated example.
* `scripts/mandate21-fis-contract.psm1` — Canonical hashing and live drift validation.
* `scripts/sync-mandate21-fis-contract.ps1` — Read-only-by-default Terraform/live verifier.
* `scripts/mandate21-fis-approval.psm1` — Strict evidence and two-gate validation.
* `scripts/mandate21-fis-approval.schema.json` — Exact approval JSON schema.
* `scripts/mandate21-fis-approval.example.json` — JSON input example accepted by the wrapper after replacement.
* `scripts/mandate21-fis-approval.example.psd1` — Human-readable field example.
* `scripts/mandate21-fis-orchestration.psm1` — Injectable fixed-order orchestration.
* `scripts/mandate21-fis-drill.ps1` — Read-only preflight and real approved skip-all execution.
* `tests/mandate21/verify-fis-contract.ps1` — Contract/hash/drift tests.
* `tests/mandate21/verify-fis-approval.ps1` — Approval rejection tests.
* `tests/mandate21/verify-fis-drill.ps1` — Mocked order/fail-fast/evidence tests.

**Documentation:**
* `docs/operations/mandate21-az-failover.md` — Current CMD-first operating procedure.
* `docs/operations/mandate21-drill-report-template.md` — Four-template evidence template.
* `docs/evidence/mandate-21/2026-07-29/fis-readiness-evidence-report.md` — Preserves capture facts and updates post-capture remediation.
* `docs/changes/2026-07-29-mandate21-fis-gap-remediation.md` — This change record.

Change trail exception for `values.schema.json`: strict JSON does not support comments; attribution is preserved in this change record.
Change trail exception for `scripts/mandate21-fis-contract.json`: strict JSON does not support comments; attribution is preserved in this change record.
Change trail exception for `scripts/mandate21-fis-contract.example.json`: strict JSON does not support comments; attribution is preserved in this change record.
Change trail exception for `scripts/mandate21-fis-approval.schema.json`: strict JSON does not support comments; attribution is preserved in this change record.
Change trail exception for `scripts/mandate21-fis-approval.example.json`: strict JSON does not support comments; attribution is preserved in this change record.

## Dependencies and Cross-Repository Impact

Related: `techx-corp-infra/docs/changes/2026-07-29-immutable-audit-dlq-archive-drain.md`. The chart approval gate consumes the infra preflight and immutable-audit evidence, but neither repository is automatically deployed by these file changes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No application runtime change while capacity overlay remains disabled. |
| **Infrastructure** | No resource creation; read-only evidence plus a Terraform output contract in the infra repository. |
| **Deployment** | Future probe enable/disable changes require Git approval and Argo reconciliation. |
| **Performance** | Probe load exists only during separately approved windows. |
| **Security** | Exact account/revision/evidence binding; hardened pod; no fallback tokens or direct cleanup. |
| **Reliability** | Fails closed on drift, incomplete alarms, stale approval, missing NodeClaim attribution, or partial FIS execution. |
| **Cost** | Not an active FIS approval gate; no resources are enabled by default. |
| **Backward compatibility** | Legacy approval switches are intentionally removed. |
| **Observability** | Adds revision-bound JSON evidence and atomic partial-run transitions. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Capacity/preflight fixtures | `pwsh -NoProfile -File tests\mandate21\verify-capacity-preflight.ps1` | PASS. |
| FIS contract | `pwsh -NoProfile -File tests\mandate21\verify-fis-contract.ps1` | PASS. |
| FIS approval | `pwsh -NoProfile -File tests\mandate21\verify-fis-approval.ps1` | PASS. |
| FIS orchestration | `pwsh -NoProfile -File tests\mandate21\verify-fis-drill.ps1` | PASS. |
| Helm/schema | `helm lint . -f values.yaml -f values-prod.yaml -f values-capacity-probe.yaml` | PASS (1 chart, 0 failures). |

### Manual Verification

Independent spec and quality/security reviews approved each implementation package after review loops. No production execution was performed.

### Remaining Verification (Post-Merge)

Collect live infra evidence, execute both capacity directions sequentially through GitOps, remediate the audit DLQs through its separate approval, wait for full alarm windows, create approval JSON, then obtain explicit approval for four FIS skip-all starts.

## Migration or Deployment Notes

1. Keep `values-capacity-probe.yaml` disabled until an approved probe window.
2. Merge/deploy infra output changes before producing the final approval pack.
3. Follow the capacity runbook twice and restore disabled state after each direction.
4. Do not run `-Execute` until all evidence hashes and live template revisions match the approval.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Contract hash drift | Medium | High | Re-verify Terraform/live templates; never bypass approval. |
| Probe left enabled | Low | Medium | Resting overlay loads last; revert through Git and verify Argo. |
| Partial FIS preview | Low | Medium | Atomic transition evidence and fail-fast ordering preserve the exact started set. |
| Legacy callers use removed switches | Medium | Medium | Update callers to the approval JSON workflow or revert the wrapper change. |

**Rollback procedure:**

Revert the chart commit through Git. Argo restores the prior desired state; because the capacity overlay is disabled, no probe workload should remain. Revert the infra output/tool commit separately if required. Never use direct Helm or kubectl rollback for Argo-managed resources.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented fail-closed preflight, capacity, approval, and four-template skip-all remediation. -->