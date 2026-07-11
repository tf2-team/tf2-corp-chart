# Change: Enable Argo CD auto-sync by default

## Context

Dev and prod Argo CD Applications used manual sync only. Auto-sync should be the
default so Git commits apply without a manual `argocd app sync`, with self-heal
for cluster drift and prune still disabled.

## Before

* `gitops/clusters/*/application.yaml` had no `syncPolicy.automated` block.
* Runbooks described first cutover / prod as manual sync.

## After

Both Applications use:

```yaml
syncPolicy:
  automated:
    prune: false
    selfHeal: true
```

Docs and operations runbook match this default. ServerSideApply remains OFF.

## Implementation

Set `automated` on Application CRs (Argo CD has no global auto-sync ConfigMap).
Updated `gitops/README.md`, `docs/operations/gitops-argocd.md`, and chart backlog.

## Files Changed

* `gitops/clusters/dev/application.yaml` — automated + selfHeal; prune false
* `gitops/clusters/prod/application.yaml` — same
* `gitops/README.md` — default policy; fixed dev app name in bootstrap
* `docs/operations/gitops-argocd.md` — bootstrap / auto-sync sections
* `docs/backlogs/2026-07-09-rel-09-gitops-argocd.md` — baseline checklist
* `docs/changes/2026-07-10-enable-argocd-auto-sync.md` — this document

## Impact

* OutOfSync apps auto-apply; live drift self-heals toward Git.
* Resource removal from Git does not prune live objects (`prune: false`).
* History rollback requires disabling auto-sync first.
* Live Applications need re-apply to pick up the policy.

## Validation

Manifest YAML reviewed. No cluster apply in this change.

```bash
kubectl apply -f gitops/clusters/dev/
argocd app get techx-corp-dev   # expect Automated, self-heal true, prune false
```

## Migration or Deployment Notes

1. Merge and apply `gitops/clusters/<env>/` into the cluster `argocd` namespace.
2. Break-glass: `argocd app set <APP> --sync-policy none`; restore via Git.

## Risks and Rollback

* Unreviewed merges can deploy automatically; protect prod paths.
* Rollback: remove `automated` (or set `enabled: false`) and re-apply Application.
