# Change: Argo ignoreDifferences for Bound PVC volumeName

## Summary

Adds `ignoreDifferences` on the production `techx-corp` Application for `PersistentVolumeClaim` `/spec/volumeName`, and enables `RespectIgnoreDifferences=true`, so Argo CD neither marks those fields OutOfSync nor applies a patch that clears the bound volume name.

## Context

After encrypt-migrate, Grafana and Prometheus PVCs are Bound to static PVs (`pv-enc-grafana`, `pv-enc-prometheus`) with `spec.volumeName` set. Helm desired manifests omit `volumeName` (dynamic bind). Argo self-heal attempted:

```text
VolumeName: "pv-enc-grafana" → ""
```

Kubernetes rejects that patch on Bound claims (`spec is immutable`), and the Application stuck on `one or more objects failed to apply`, blocking other resources (including OpenSearch STS rolls).

## Before

* No `ignoreDifferences` for PVCs on `gitops/clusters/prod/application.yaml`.
* Sync failed on grafana/prometheus PVC volumeName patches.
* Live PVCs remained Bound and correct; Argo status OutOfSync/Failed.

## After

* Application ignores `/spec/volumeName` on all PVCs for comparison **and** apply.
* `syncOptions` includes `RespectIgnoreDifferences=true` (required: without it, ignoreDifferences only affects status while sync still patches empty volumeName).
* Encrypted static PV binding is preserved; other resources can sync.

## Technical Design Decisions

* Ignore **all** PVC `volumeName` fields, not only grafana/prometheus — Helm never owns this field; the API always sets it after bind for dynamic claims too.
* **`RespectIgnoreDifferences=true`** is mandatory with self-heal; first commit only set ignoreDifferences and sync still failed on immutable patches.
* Do not delete/recreate PVCs in Git — that would risk data loss.

## Implementation Details

1. Added `spec.ignoreDifferences` for PVC `/spec/volumeName`.
2. Added `RespectIgnoreDifferences=true` under `syncPolicy.syncOptions`.
3. Root App of Apps / Argo reconciles the Application CR from `gitops/clusters/prod` on `main`.

## Files Changed

* `gitops/clusters/prod/application.yaml` — ignore PVC `/spec/volumeName`.
* `docs/changes/2026-07-22-argocd-ignore-pvc-volumename.md` — this record.

## Dependencies and Cross-Repository Impact

None. Follow-up to encrypted PVC rebind (`2026-07-22-encrypted-storageclass-and-pvc-sc.md`).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Unblocks Argo sync; no PVC data change |
| **Deployment** | GitOps only (Application CR update via root-prod) |
| **Reliability** | Stops failed sync loops from immutable PVC fields |
| **Backward compatibility** | Safe for all Bound PVCs |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Manifest syntax | YAML Application with ignoreDifferences | Applied in Git |

### Manual Verification

* After Argo refreshes Application: sync no longer errors on grafana/prometheus volumeName.
* `kubectl get pvc -n techx-corp-prod grafana prometheus` still Bound to `pv-enc-*`.

### Remaining Verification (Post-Merge)

* Confirm Application `Synced`/`Healthy` (or Progressing only for app health).
* OpenSearch STS roll can proceed once sync is unblocked.

## Migration or Deployment Notes

1. Push/merge this change to `main` (prod Application path is GitOps-managed by `root-prod`).
2. Wait for `root-prod` / Argo to update Application `techx-corp` ignoreDifferences.
3. Allow automated sync to retry; no PVC recreation required.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| volumeName drift ignored intentionally | Low | Low | Desired state never set volumeName |

**Rollback procedure:** Remove `ignoreDifferences` block via Git revert (only if needed).

<!-- Change trail: @hungxqt - 2026-07-22 - RespectIgnoreDifferences for Bound PVC volumeName. -->
