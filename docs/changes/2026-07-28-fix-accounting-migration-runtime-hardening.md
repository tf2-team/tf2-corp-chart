# Change: Fix Accounting Migration PreSync Job Runtime Hardening Compliance

## Summary

Configured explicit `securityContext` (`runAsNonRoot: true`, `runAsUser: 10001`, `runAsGroup: 10001`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ["ALL"]`), `podSecurityContext` (`seccompProfile.type: RuntimeDefault`), and container resource requests/limits on `templates/accounting-migration-job.yaml` to comply with the Mandate 5 `runtime-hardening-pod-template.techx.io` ValidatingAdmissionPolicy.

## Context

The Mandate 21 PreSync `accounting-migration` Job failed verification in `scripts/verify-runtime-hardening.ps1` because the container specification lacked `runAsNonRoot`, `allowPrivilegeEscalation: false`, dropped capabilities, and CPU/memory resource requests/limits required by cluster admission policy `runtime-hardening-pod-template.techx.io`.

## Before

`templates/accounting-migration-job.yaml` defined a partial `securityContext` (`runAsUser: 10001`, `runAsGroup: 10001`) without `runAsNonRoot`, `allowPrivilegeEscalation`, dropped capabilities, or container `resources`. When rendered for production admission testing, `kubectl apply --dry-run=server` failed with exit code 1 due to policy denial.

## After

`templates/accounting-migration-job.yaml` defines a complete workload hardening spec:
* Pod `securityContext`: `seccompProfile.type: RuntimeDefault`.
* Container `resources`: Inherits `$acct.resources` or `.Values.default.resources` (CPU request 20m, limit 100m; Memory request 256Mi, limit 384Mi).
* Container `securityContext`: `runAsNonRoot: true`, `runAsUser: 10001`, `runAsGroup: 10001`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `capabilities.drop: ["ALL"]`.

## Technical Design Decisions

* Inherited `$acct.resources` to stay aligned with the main `accounting` microservice resources defined in `values.yaml`.
* Configured `readOnlyRootFilesystem: true` and `seccompProfile: RuntimeDefault` to maintain full compliance with Mandate 5 runtime security standards.

## Implementation Details

1. Updated `templates/accounting-migration-job.yaml` with `podSecurityContext`, container `resources`, and hardened `securityContext`.
2. Verified template rendering with `helm template`.
3. Verified verification script execution with `scripts/verify-runtime-hardening.ps1`.

## Files Changed

**Templates:**
* `templates/accounting-migration-job.yaml` — Added pod securityContext, container resources, and hardened container securityContext.

**Documentation:**
* `docs/changes/2026-07-28-fix-accounting-migration-runtime-hardening.md` — This change record.

## Dependencies and Cross-Repository Impact

None.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | `accounting-migration` Job runs under hardened non-root security context and defined resource limits during Argo CD PreSync. |
| **Infrastructure** | No change |
| **Deployment** | Mandate 21 PreSync migration job complies with cluster VAP enforce policy during GitOps sync. |
| **Performance** | No change |
| **Security** | Prevents privilege escalation and drops root capabilities for accounting database migration jobs. |
| **Reliability** | Job pods get predictable resource scheduling from Karpenter. |
| **Cost** | No change |
| **Backward compatibility** | Fully backward-compatible |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm Lint | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | ✅ Pass |
| VAP Contract Verification | `pwsh -ExecutionPolicy Bypass -File scripts/verify-runtime-hardening.ps1` | ✅ Pass |

### Manual Verification

Rendered `templates/accounting-migration-job.yaml` using `helm template techx-corp . --namespace techx-corp-prod -f values-public-alb.yaml -f values-prod.yaml -s templates/accounting-migration-job.yaml` and verified presence of all required VAP fields.

### Remaining Verification (Post-Merge)

* Confirm successful execution of `accounting-migration` PreSync Job during Argo CD sync in production.

## Migration or Deployment Notes

None.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Migration Job fails if container writes to read-only root FS | Low | Medium | Revert `readOnlyRootFilesystem: true` or mount emptyDir `/tmp` if necessary. |

**Rollback procedure:**

Revert changes to `templates/accounting-migration-job.yaml`.

<!-- Change trail: @hungxqt - 2026-07-28 - Add change document for accounting-migration runtime hardening fix. -->
