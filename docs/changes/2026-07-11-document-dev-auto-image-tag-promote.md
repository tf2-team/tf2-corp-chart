# Change: Document automated dev image tag promotion

## Summary

Updated the GitOps runbook so operators know development image tags are promoted by platform CI via a direct push to `values-dev.yaml` on `techx-dev-corp` after a successful full ECR publish, while production remains a manual values PR.

## Context

Platform CI (REL-09 Phase 6) now automates writing `default.image.tag` for development after `release-ready`. The chart repository itself does not host that workflow, but operators reading the chart runbook need the accurate promote path so they do not open redundant manual dev PRs or assume prod is also automated.

## Before

Promote section described a single manual flow for both `values-dev.yaml` and `values-prod.yaml` after full bake + ECR verify.

## After

Promote section documents:

* **Development:** platform job `update-chart-dev` direct-pushes `default.image.tag` on branch `techx-dev-corp` → Argo Application `techx-corp-dev` auto-syncs.
* **Production:** still manual PR on `values-prod.yaml`.
* Pointer to platform workflow + `CHART_REPO_TOKEN` setup.
* **Operator setup summary** table: fine-grained PAT → platform secret `CHART_REPO_TOKEN` → optional vars → chart branch push rules → verify; auth model (PAT authorizes push; commit may show as `github-actions[bot]`); link to full platform `docs/CICD.md` §4.

No chart templates, values defaults, or gitops Application YAML were changed in this documentation-only update.

## Technical Design Decisions

* Documentation-only in chart repo; automation lives in `techx-corp-platform`.
* Keep prod manual path explicit to avoid unsafe auto-promotion.

## Implementation Details

1. Edited `docs/operations/gitops-argocd.md` promote section (dev auto vs prod manual).
2. Added operator setup summary table + auth model + link to platform CICD §4.
3. Added / updated this change record.

## Files Changed

**Documentation:**

* `docs/operations/gitops-argocd.md` — Split promote flows; operator setup summary for PAT/secret/branch rules.
* `docs/changes/2026-07-11-document-dev-auto-image-tag-promote.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-11-auto-promote-dev-chart-image-tag.md`
* Depends on platform workflow merge + `CHART_REPO_TOKEN` for automation to actually write this repo.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change from this docs edit alone |
| **Deployment** | Clarifies expected source of `values-dev.yaml` tag updates |
| **Backward compatibility** | Manual promote still valid if automation is disabled |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A (docs only) | — | N/A |

### Manual Verification

* Runbook text matches platform workflow design (dev direct push; prod manual).

### Remaining Verification (Post-Merge)

* After platform automation is live, confirm a bot commit updates `values-dev.yaml` as documented.

## Migration or Deployment Notes

None for this docs change. Operators enabling automation should configure `CHART_REPO_TOKEN` on the platform repo and allow the bot to push to `techx-dev-corp`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Docs drift if platform design changes | Low | Low | Update runbook with workflow changes |

**Rollback procedure:** Revert this documentation commit.
