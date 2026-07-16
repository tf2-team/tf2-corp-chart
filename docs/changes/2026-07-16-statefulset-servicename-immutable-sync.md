# Change: Set StatefulSet serviceName to fix Argo apply on OpenSearch

## Summary

StatefulSet templates now set `spec.serviceName` to the component name. This
aligns Git desired state with the live `opensearch` StatefulSet (which already
has `serviceName: opensearch` from a prior chart apply) and stops Argo CD from
patching an immutable field after the temporary chart revert.

## Context

* Argo sync failed with:
  `StatefulSet.apps "opensearch" is invalid: spec: Forbidden: updates to
  statefulset spec for fields other than 'replicas', 'ordinals', 'template',
  'updateStrategy', 'revisionHistoryLimit', 'persistentVolumeClaimRetentionPolicy'
  and 'minReadySeconds' are forbidden`.
* Live prod `opensearch` STS has `serviceName: opensearch` and chart label from
  `techx-corp-0.48.7` (briefly applied).
* Revert commit `d03e800` removed `serviceName` from the template again. Desired
  manifests omitted the field (effectively empty); Argo tried to clear live
  `serviceName` → API rejected the patch.
* `serviceName` is immutable for the life of a StatefulSet.

## Before

* Template did not render `spec.serviceName` for StatefulSets.
* Live `opensearch`: `serviceName: opensearch`.
* Live `postgresql` / `kafka`: empty `serviceName`.

## After

* Every StatefulSet renders `serviceName: <component name>` (e.g. `opensearch`,
  `postgresql`, `kafka`).
* Chart version `0.48.7`.

## Technical Design Decisions

* **Match live OpenSearch rather than delete/recreate it** — OpenSearch already
  has the correct non-empty `serviceName`; chart should emit the same value.
* **Always set serviceName for all stateful components** — required Kubernetes
  field for stable network identity; empty string is a historical gap.
* **postgresql (and any STS still with empty serviceName)** cannot be *patched*
  to a non-empty value. After this chart lands, those objects need a one-time
  `kubectl delete statefulset <name> --cascade=orphan` so Argo recreates them
  with `serviceName` while **keeping PVCs**.

## Implementation Details

1. In `templates/_objects.tpl`, for `.stateful` workloads, set
   `serviceName: {{ .name }}` next to the Deployment-only strategy block.
2. Bump `Chart.yaml` to `0.48.7` so live labels reflect the fix revision.

## Files Changed

**Templates:**

* `templates/_objects.tpl` — StatefulSet `serviceName`.

**Chart metadata:**

* `Chart.yaml` — version `0.48.7`.

**Documentation:**

* `docs/changes/2026-07-16-statefulset-servicename-immutable-sync.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Cluster follow-up is operator kubectl for STS with empty `serviceName` only.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No intentional runtime change once desired matches live |
| **Deployment** | Unblocks Argo sync for `opensearch`; `postgresql` may need orphan STS recreate |
| **Reliability** | Correct StatefulSet network identity field |
| **Data** | PVC retained if recreate uses `--cascade=orphan` |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Render | `helm template ...` includes `serviceName: opensearch` | Pending local verify |

### Manual Verification

* Live: `kubectl -n techx-corp-prod get sts opensearch -o jsonpath={.spec.serviceName}` → `opensearch`.
* Confirmed empty serviceName on postgresql/kafka.

### Remaining Verification (Post-Merge)

1. Merge and wait Argo sync for `opensearch` (should succeed).
2. If postgresql fails with the same Forbidden error:

```cmd
kubectl -n techx-corp-prod get sts postgresql -o jsonpath="{.spec.serviceName}{'\n'}"
REM only if empty — keep PVC:
kubectl -n techx-corp-prod delete statefulset postgresql --cascade=orphan
argocd app wait techx-corp --sync --health --timeout 600
```

3. Do **not** delete PVCs as part of this fix.

## Migration or Deployment Notes

1. Push chart to the branch Argo tracks (`main`).
2. Prefer normal PR merge if force-push is blocked by branch protection.
3. After sync: OpenSearch healthy; PostgreSQL recreated only if serviceName was empty.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| postgresql sync fails until orphan recreate | High if serviceName empty | Medium | Documented cascade=orphan delete; PVC retained |
| Operator deletes STS without orphan cascade | Low | High | Doc requires `--cascade=orphan` |

**Rollback procedure:**

Re-omitting `serviceName` from the template will break OpenSearch sync again while
live still has `serviceName: opensearch`. Do not roll back without recreating the
OpenSearch STS to match.

<!-- Change trail: @hungxqt - 2026-07-16 - StatefulSet serviceName to fix immutable field Argo apply. -->
