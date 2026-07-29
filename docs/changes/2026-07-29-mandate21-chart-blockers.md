# Change: Mandate 21 Gate Approvals, Preflight Collector, and Karpenter Capacity Probe

## Summary

Bound FIS experiment execution and reports to FIS template IDs and canonicalized `revisionSha256` hashes, replaced discrete approval flags with `-ApprovalFile <gate-approval.json>`, implemented sequential `skip-all` experiment verification, created fail-closed infrastructure preflight collector (`scripts/collect-infra-preflight.ps1`), created Helm `capacity-probe` Deployment template, and added capacity probe runner script (`scripts/run-capacity-probe.ps1`).

## Context

Mandate 21 requires strict gate controls for FIS availability zone failover drills. Execution must bind to canonicalized live template revisions and explicit gate approvals, preview must run real `skip-all` FIS experiments, infrastructure must be preflight-validated (Route/NAT, RDS, Valkey, DynamoDB deletion protection, MSK), and Karpenter capacity failover must be proven.

## Before

* FIS wrapper accepted discrete `-CapacityApproved`, `-CostApproved`, `-DurabilityApproved`, `-ChangeApproved` switches without binding to template `revisionSha256` hashes.
* No dedicated script collected fail-closed infrastructure preflight evidence (`infra-preflight.json`).
* Helm chart lacked `capacity-probe` Deployment for proving Karpenter node provisioning in surviving AZs.
* Cost section was present in FIS execution pack requirements.

## After

* FIS wrapper enforces `-ApprovalFile <gate-approval.json>` bound to account, region, cluster, four template IDs, canonicalized `revisionSha256`, `CapacityApproved=PASS`, `ChangeApproved=PASS`, and unexpired `validUntil`.
* `scripts/collect-infra-preflight.ps1` generates `infra-preflight.json` and Markdown summary verifying Route/NAT, RDS, Valkey, DynamoDB deletion protection, and MSK topology.
* `templates/capacity-probe.yaml` provides disabled-by-default Karpenter capacity proof Deployment pinned to surviving AZs with stateless-on-demand placement and spot-tolerant toleration.
* `scripts/run-capacity-probe.ps1` executes read-only Karpenter capacity verification.
* Cost section is stripped from gate approval and delivery reports.

## Technical Design Decisions

* **Canonical Template Hashing:** Live FIS experiment templates are canonicalized to compute a deterministic SHA-256 hash (`revisionSha256`) along with AWS `lastUpdateTime` to prevent drift.
* **Skip-all Execution:** `-ActionsMode skip-all` executes 4 real FIS experiment runs sequentially using `--experiment-options actionsMode=skip-all` to verify target selectors, stop alarms, and FIS engine behavior without interrupting traffic.
* **No Direct Secret Access:** PowerShell wrappers call the Go reconciler and preflight checks without inspecting Kubernetes Secret data directly.

## Implementation Details

1. Updated `scripts/mandate21-fis-drill.ps1` to accept `-ApprovalFile`, calculate template `revisionSha256`, validate approvals, and run sequential `skip-all` experiments.
2. Created `templates/capacity-probe.yaml`, updated `values.yaml` and `values.schema.json` to configure Karpenter capacity proof Deployment.
3. Created `scripts/collect-infra-preflight.ps1` for fail-closed infrastructure preflight checks.
4. Created `scripts/run-capacity-probe.ps1` for Karpenter capacity proof validation.
5. Updated `tests/mandate21/verify-runtime.ps1` with capacity-probe tests and verified clean execution.

## Files Changed

**Configuration & Templates:**
* `values.yaml` — Added `capacityProbe` configuration block (disabled by default).
* `values.schema.json` — Added `capacityProbe` JSON schema definition. Change trail exception for `values.schema.json`: JSON data format does not support comment syntax; attributed to @hungxqt.
* `templates/capacity-probe.yaml` — Added Karpenter capacity-probe Deployment template.

**Scripts:**
* `scripts/mandate21-fis-drill.ps1` — Updated to enforce `-ApprovalFile`, canonical template hashing, and sequential `skip-all` experiment execution.
* `scripts/collect-infra-preflight.ps1` — Added fail-closed infrastructure preflight collector.
* `scripts/run-capacity-probe.ps1` — Added read-only Karpenter capacity probe verification runner.
* `tests/mandate21/verify-runtime.ps1` — Added capacity-probe tests.

**Documentation:**
* `docs/changes/2026-07-29-mandate21-chart-blockers.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-29-mandate21-platform-blockers.md`
* Related: `techx-corp-infra/docs/changes/2026-07-29-mandate21-infra-blockers.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime impact on production microservices; capacity-probe is disabled by default |
| **Infrastructure** | Enables Karpenter capacity proof in surviving AZs during failover drills |
| **Deployment** | Reconciled via Argo CD; capacity probe enabled only during drills via Git overlay |
| **Performance** | Zero impact on production workloads |
| **Security** | `capacity-probe` runs with `automountServiceAccountToken: false` and non-root security context |
| **Reliability** | Proves Karpenter node provisioning and AZ failover headroom before live fault injection |
| **Cost** | Cost section stripped from gate requirements; capacity probe runs briefly during drills |
| **Backward compatibility** | Fully backward-compatible |
| **Observability** | Integrates preflight and capacity evidence into Mandate 21 delivery reports |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Mandate 21 Runtime Tests | `powershell.exe -ExecutionPolicy Bypass -File tests/mandate21/verify-runtime.ps1` | ✅ Pass |
| Helm Template Validation | `helm template techx-corp . ... --set capacityProbe.enabled=true` | ✅ Pass |

### Manual Verification

* Verified `verify-runtime.ps1` executes all 65 test assertions cleanly.
* Verified `capacity-probe.yaml` renders correctly when enabled and is omitted when disabled.

### Remaining Verification (Post-Merge)

* Execute 4 sequential FIS `skip-all` experiment runs against dev/prod templates.

## Migration or Deployment Notes

None.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Capacity probe leaves leftover pods | Low | Low | Disabled by default; Git revert / Argo CD sync prunes all probe resources |

**Rollback procedure:**

Revert Git commit in `techx-corp-chart`.

<!-- Change trail: @hungxqt - 2026-07-29 - Document Mandate 21 chart blocker resolutions, preflight collector, and Karpenter capacity probe. -->
