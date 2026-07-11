# Change: Document OpenSearch subchart orphan cleanup for Argo CD

## Summary

Document the one-time cluster cleanup for leftover OpenSearch Helm subchart
resources (`opensearch-config`, `opensearch-headless`, `opensearch-pdb`) that
cause Argo CD OutOfSync/Orphaned after the first-party OpenSearch migration.
No chart templates or values were changed.

## Context

OpenSearch was moved from the official subchart (`opensearch-3.6.0`) to
`components.opensearch` (see `2026-07-10-opensearch-first-party-component.md`).
Argo CD Applications use `prune: false`, so objects no longer in the rendered
manifest stay on the cluster with the app tracking label and appear OutOfSync.
Operators need explicit resource names and safe delete commands.

## Before

* Migration notes mentioned generic orphan cleanup without naming the three
  subchart-only resources.
* GitOps ops doc had no OpenSearch-specific orphan section.

## After

* `docs/operations/gitops-argocd.md` lists the orphan kinds/names, labels to
  match, and kubectl delete steps; warns not to delete the first-party
  `opensearch` Service/StatefulSet.
* First-party migration change doc points at the same cleanup list.

## Technical Design Decisions

* **Manual delete, not prune: true** — keep Application `prune: false` for
  safety; document a targeted one-time cleanup instead of enabling auto-prune.
* **Label gate** — require `helm.sh/chart=opensearch-3.6.0` before delete so
  first-party (`helm.sh/chart: techx-corp-*`) objects are not removed.

## Implementation Details

1. Added § Orphan cleanup to GitOps operations doc.
2. Tightened migration notes on the first-party OpenSearch change record.

## Files Changed

**Documentation:**
* `docs/operations/gitops-argocd.md` — Orphan cleanup section for OpenSearch subchart leftovers.
* `docs/changes/2026-07-10-opensearch-first-party-component.md` — Explicit resource names + link.
* `docs/changes/2026-07-11-opensearch-subchart-orphan-cleanup.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Cluster-side kubectl cleanup only; no platform or infra code changes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change from this doc-only update |
| **Deployment** | Operators manually delete three orphan objects once per affected cluster |
| **Backward compatibility** | N/A |
| **Observability** | Argo CD app should leave OutOfSync for those orphans after cleanup |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A | Doc-only | N/A |

### Manual Verification

* Compared live objects (user-provided) against chart: ConfigMap/Service/PDB only
  exist in old subchart; first-party renders StatefulSet + Service `opensearch`.
* PDB status `expectedPods: 0` matches selector mismatch with first-party labels.

### Remaining Verification (Post-Merge)

* On each cluster still showing OutOfSync for these names, run the documented
  delete commands and confirm `argocd app get` is Sync.

## Migration or Deployment Notes

1. On the affected cluster/namespace, delete only objects labeled
   `helm.sh/chart=opensearch-3.6.0` as documented.
2. Do not enable Application prune solely for this cleanup.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operator deletes live first-party `opensearch` Service | Low | High | Doc requires chart-label check; keep Service named `opensearch` |

**Rollback procedure:**

Revert this documentation commit. Cluster objects already deleted stay deleted
unless restored from a prior backup or recreated by re-adding the subchart
(not recommended).
