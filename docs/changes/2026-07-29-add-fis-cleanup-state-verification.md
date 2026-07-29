# Change: Add FIS Deterministic Cleanup State Verification

## Summary

This change introduces deterministic, fail-closed runtime cleanup verification (`cleanup-state.json`) and pure evaluation functions (`mandate21-cleanup.psm1`) to `techx-corp-chart`. It updates the Mandate 21 drill wrapper (`mandate21-fis-drill.ps1`), contract JSON files, runbook, drill report template, and unit test suites to automatically evaluate eight read-only cleanup checks post-experiment without mutating AWS, Kubernetes, or Helm state.

## Context

During Mandate 21 FIS chaos drills, validating residual resource cleanup (restored subnet NACLs, restarted/replaced EC2 target nodes, RDS and Valkey primary health, CloudWatch stop alarm stability, and Kubernetes capacity) must be fail-closed, deterministic, and verifiable. Adding pure cleanup functions and atomic `cleanup-state.json` updates allows drill operators to record concrete audit evidence without introducing automated remediation scripts or expanding IAM roles.

## Before

* `scripts/mandate21-fis-drill.ps1` polled FIS experiment status until terminal state but did not generate a structured `cleanup-state.json` artifact or systematically evaluate read-only post-experiment cleanup checks.
* No standalone pure PowerShell module existed for FIS cleanup evaluation.
* `mandate21-fis-contract.json` and `mandate21-fis-contract.example.json` contained `schemaVersion`, `region`, `clusterContext`, `namespace`, `storefrontUrl`, `rdsInstanceIdentifier`, and `zones`, but omitted `cleanupByTemplateId`.
* No fixture-driven unit test suite existed for testing cleanup state scenarios (residual NACL, stopped EC2 instance, failed RDS failover, etc.).

## After

* Created `scripts/mandate21-cleanup.psm1` containing pure evaluation functions (`Test-FisPostActions`, `Test-NetworkAclRestored`, `Test-Ec2Recovered`, `Test-RdsHealthy`, `Test-ValkeyHealthy`, `Test-StopAlarmsStable`, `Test-KubernetesRecovered`, `Evaluate-FisCleanup`, `Save-FisCleanupState`).
* Extended `scripts/mandate21-fis-drill.ps1` to capture subnet NACL mappings and target instance metadata pre-fault, poll read-only checks post-experiment, and write `cleanup-state.json` atomically after every state transition.
* Updated `mandate21-fis-contract.json` and `mandate21-fis-contract.example.json` with additive `cleanupByTemplateId` policy definitions.
* Created `tests/mandate21/verify-cleanup.ps1` with 11 fixture-driven unit tests covering completed, stopped, failed, residual NACL, stopped target, RDS/Valkey direction error, alarm window instability, query failure, `skip-all` mode (`NOT_APPLICABLE`), and static proof of zero mutating AWS/kubectl/Helm commands.
* Updated `tests/mandate21/verify-runtime.ps1`, `docs/operations/mandate21-az-failover.md`, and `docs/operations/mandate21-drill-report-template.md`.

## Technical Design Decisions

* **Pure Evaluation Module**: Kept all AWS and kubectl CLI calls outside `mandate21-cleanup.psm1` so that all 8 checks can be tested deterministically using in-memory data fixtures.
* **Non-Mutating Verifier**: The verifier only performs read-only inspection. It never calls `start-instances`, `replace-network-acl-association`, `set-alarm-state`, or mutating `kubectl` / `helm` commands.
* **Atomic State Persistence**: `cleanup-state.json` is written via temporary file `.tmp` and moved to ensure crash-consistent atomic disk updates.

## Implementation Details

1. Added `scripts/mandate21-cleanup.psm1` pure evaluation module.
2. Updated `scripts/mandate21-fis-drill.ps1` to record pre-fault NACL / EC2 baselines and run post-fault cleanup evaluation loops.
3. Updated contract JSON files (`mandate21-fis-contract.example.json` and `mandate21-fis-contract.json`) to include `cleanupByTemplateId`.
4. Added `tests/mandate21/verify-cleanup.ps1` fixture unit tests.
5. Updated `tests/mandate21/verify-runtime.ps1` to parse `mandate21-cleanup.psm1` and assert `cleanupByTemplateId`.
6. Updated operational runbook `docs/operations/mandate21-az-failover.md` and report template `docs/operations/mandate21-drill-report-template.md`.

## Files Changed

**Scripts & Module:**
* `scripts/mandate21-cleanup.psm1` — Pure cleanup evaluation module.
* `scripts/mandate21-fis-drill.ps1` — Updated drill wrapper with baseline capture and `cleanup-state.json` atomic writer.

**Contract Files:**
* `scripts/mandate21-fis-contract.example.json` — Added `cleanupByTemplateId` schema example.
* `scripts/mandate21-fis-contract.json` — Added `cleanupByTemplateId` map with four active template IDs.

**Tests:**
* `tests/mandate21/verify-cleanup.ps1` — 11 fixture-driven unit tests for cleanup state evaluation.
* `tests/mandate21/verify-runtime.ps1` — Added AST parse and `cleanupByTemplateId` assertions.

**Documentation:**
* `docs/operations/mandate21-az-failover.md` — Updated runbook with `cleanup-state.json` verification instructions.
* `docs/operations/mandate21-drill-report-template.md` — Added cleanup status, failed checks, and artifact path fields.
* `docs/changes/2026-07-29-add-fis-cleanup-state-verification.md` — This change document.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-infra/docs/changes/2026-07-29-add-fis-cleanup-contract.md`
* Expects `cleanupByTemplateId` output from `techx-corp-infra` `mandate21_fis_contract`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No impact on application workloads. |
| **Infrastructure** | Zero infrastructure change in this repository. |
| **Deployment** | No Helm release or deployment required. |
| **Performance** | Minimal overhead during drill execution (15s read-only polling). |
| **Security** | Zero IAM changes; verifier operates strictly read-only. |
| **Reliability** | Fail-closed verification prevents residual FIS faults from being overlooked. |
| **Cost** | Zero additional cost. |
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Produces structured `cleanup-state.json` audit evidence. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Runtime Verification | `powershell -NoProfile -ExecutionPolicy Bypass -File tests\mandate21\verify-runtime.ps1` | ✅ Pass |
| Cleanup State Tests | `powershell -NoProfile -ExecutionPolicy Bypass -File tests\mandate21\verify-cleanup.ps1` | ✅ Pass |
| Git Diff Check | `git diff --check` | ✅ Pass |

### Manual Verification

* Verified all 11 unit test scenarios pass cleanly without any live AWS or Kubernetes connection.

### Remaining Verification (Post-Merge)

* Execute preview drills (`skip-all`) post-apply to confirm `NOT_APPLICABLE` output.

## Migration or Deployment Notes

* None.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| PowerShell syntax error | Low | Low | Validated via AST parser in `verify-runtime.ps1`. |

**Rollback procedure:**

1. Revert changes in `scripts/mandate21-fis-drill.ps1`, `scripts/mandate21-fis-contract.json`, and remove `scripts/mandate21-cleanup.psm1`.

## Per-File Change Trail Exceptions

Change trail exception for `scripts/mandate21-fis-contract.example.json`: Strict JSON format does not support comments; change trail is recorded in this change document by @hungxqt on 2026-07-29.
Change trail exception for `scripts/mandate21-fis-contract.json`: Strict JSON format does not support comments; change trail is recorded in this change document by @hungxqt on 2026-07-29.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented deterministic FIS cleanup state verification implementation. -->
