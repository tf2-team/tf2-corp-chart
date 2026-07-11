# Change: OpenSearch as first-party component (remove Helm subchart)

## Context

OpenSearch was installed via the official Helm subchart, which could not inherit `default.image`. That forced a separate `opensearch.image` block in env overlays and dual-tag promotions. The platform already builds a custom OpenSearch image (`src/opensearch/Dockerfile`) into ECR under the same bake catalog as other services.

## Before

* Chart dependency: `opensearch` 3.6.0 from OpenSearch Helm repo.
* Image set under top-level `opensearch.image.repository` / `tag`.
* Overlays (`values-dev.yaml` / `values-prod.yaml`) had to keep OpenSearch tags in sync with `default.image.tag`.

## After

* OpenSearch Helm subchart **removed**.
* OpenSearch is a first-party `components.opensearch` StatefulSet (same template path as kafka/postgresql).
* Image: `{{ default.image.repository }}/opensearch:{{ default.image.tag }}` (custom ECR image; no `imageOverride`).
* Env overlays only set `default.image` for all nested services including OpenSearch.

## Implementation

1. Removed dependency from `Chart.yaml` / `Chart.lock` and deleted `charts/opensearch-*.tgz`.
2. Added `components.opensearch` in `values.yaml` (single-node, security plugin disabled, resources, emptyDir data path).
3. Registered `opensearch` in `values.schema.json` Components.
4. Stripped `opensearch.image` from `values-dev.yaml` / `values-prod.yaml`.
5. Updated deployment / GitOps docs for single-tag contract.

## Files Changed

* `Chart.yaml`, `Chart.lock`, `charts/` — drop OpenSearch subchart dependency.
* `values.yaml` — `components.opensearch` first-party config; remove top-level subchart values.
* `values-dev.yaml`, `values-prod.yaml` — image via `default.image` only.
* `values.schema.json` — component schema entry.
* `docs/DEPLOYMENT.md`, `docs/operations/gitops-argocd.md`, `SEC-04-notes.md` — single image contract.
* `docs/changes/2026-07-10-opensearch-first-party-component.md` — this log.

## Impact

* **Application behavior:** Still serves HTTP on `opensearch:9200` for OTEL / Grafana.
* **Deployment:** One tag key per env; OpenSearch rolls with the same VERSION as other bake services.
* **Upgrade note:** Existing subchart resources may need a one-time cleanup if resource names/labels differ (Service name remains `opensearch`).

## Validation

```bash
helm dependency update
helm template test . -f values.yaml -f values-public-alb.yaml -f values-dev.yaml \
  | findstr /C:"techx-dev-corp/opensearch" /C:"name: opensearch"
# Expected image: …/techx-dev-corp/opensearch:sha-<tag from values-dev>
```

## Migration or Deployment Notes

1. Ensure ECR has `PROJECT/opensearch:<tag>` for the active `default.image.tag`.
2. After first sync with this chart: delete **orphaned subchart** resources once
   (Argo `prune: false` will not remove them). Typical leftovers labeled
   `helm.sh/chart: opensearch-3.6.0`:
   * ConfigMap `opensearch-config`
   * Service `opensearch-headless`
   * PodDisruptionBudget `opensearch-pdb`
   Keep the first-party Service/StatefulSet named `opensearch`. See
   `docs/operations/gitops-argocd.md` § Orphan cleanup.
3. Promote tags by editing **only** `default.image.tag` in the env overlay.

## Risks and Rollback

* **Risk:** OpenSearch first boot slower; env-based single-node config differs slightly from upstream chart defaults.
* **Risk:** Orphaned subchart resources after cutover.
* **Rollback:** Restore previous chart revision that still depends on the OpenSearch subchart (not recommended long-term).
