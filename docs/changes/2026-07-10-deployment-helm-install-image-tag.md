# Change: Document Helm cold install and image-tag upgrade commands

## Context

Operators needed clear, copy-ready Helm commands for (1) installing the platform from nothing and (2) rolling a new global image tag. The DEPLOYMENT runbook had break-glass snippets but not a full cold-install sequence or an explicit image-tag-only path (including the OpenSearch tag contract).

## Before

- Phase 4B listed prod/dev `helm upgrade --install` once each, without install-from-nothing ordering detail or a dedicated image-tag update section.
- Image promotion was mainly described under GitOps (4A), not as parallel Helm commands.

## After

- Phase 4B restructured into:
  - **B1. Install from nothing** — kubeconfig, dependency build, secrets-chart wait Ready, app chart with full value layers (dev + prod).
  - **B2. Update image tag only** — GitOps preferred, Helm full `-f` overlay, and Helm `--set` for both `default.image.tag` and `opensearch.image.tag`.
- Cold install / tag upgrade timeout documented as `15m`; post-install and post-tag verify commands included.

## Implementation

Documentation-only update to `docs/DEPLOYMENT.md`.

## Files Changed

* `docs/DEPLOYMENT.md`
  * Expanded §4B with cold install and image-tag upgrade Helm/GitOps commands.
* `docs/changes/2026-07-10-deployment-helm-install-image-tag.md`
  * This change record.

## Impact

* **Deployment:** Operators have a single runbook section for first install and tag bumps without guessing release names, value layers, or secrets order.
* **Application behavior / infrastructure:** None (docs only).

## Validation

* Reviewed commands against existing constants table (release/namespace, value files) and secrets-chart SEC-05 order in the same document.
* Confirmed OpenSearch tag co-update is stated in both GitOps and Helm paths.

## Migration or Deployment Notes

None.

## Risks and Rollback

None (documentation). Revert the DEPLOYMENT.md section if wording needs adjustment.
