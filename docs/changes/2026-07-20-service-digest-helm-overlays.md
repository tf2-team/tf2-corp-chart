# Change: Helm service-digest overlays for selective image pins

## Summary

Introduced chart folder `service-digest/` for per-service immutable image digests, taught templates to render `image@sha256:…` when digests are present, extended values schema for digest fields, and wired Argo CD dev/prod Applications to load every `service-digest/values-*.yaml` overlay after the env values file.

## Context

Platform CI (Mandate 10 secure delivery) promotes only **rebuilt** service digests. Those overlays must live under **`service-digest/`** (operator requirement) and be consumed by Helm so Argo deploys pinned digests instead of tag-only references. Without chart support, platform promote commits would not change running workloads.

## Before

* Container images always used `repository:tag` (`default.image` + optional `imageOverride`).
* No `service-digest/` directory or Argo valueFiles for per-service digests.
* `values.schema.json` rejected `imageOverride.digest`, `mem0.image.digest`, and `sidecarImageDigests`.

## After

* `service-digest/values-<service>.yaml` placeholders for all 23 release services (plus README).
* Helper `techx-corp.containerImage` resolves tag or digest for main containers and sidecars.
* Flagd UI digests apply via `components.flagd.sidecarImageDigests` without replacing `sidecarContainers`.
* Mem0 migrate/main/cleanup containers honor `mem0.image.digest` (tag still used for model-delivery S3 path).
* Dev/prod Argo Applications list all service-digest valueFiles after env overlays.
* Schema allows digest pins with `sha256:[0-9a-f]{64}` pattern.

## Technical Design Decisions

* **Placeholders for all 23 services** — Argo valueFiles cannot omit missing files; empty placeholders keep Helm valid until first promote.
* **Digest preferred over tag when set** — registry pull by digest; global tag remains for services without a digest overlay.
* **Non-destructive flagd-ui map** — avoid wiping sidecar config arrays on promote.
* **Schema pattern on digests** — fail closed on malformed pins during `helm` validation.

## Implementation Details

1. Added `templates` helper `techx-corp.containerImage` in `_helpers.tpl`.
2. Updated `_objects.tpl` main + sidecar image lines to use the helper (and `sidecarImageDigests`).
3. Updated `mem0.yaml` to build `$imageRef` with optional digest for all mem0 containers.
4. Created `service-digest/` placeholders + README.
5. Extended `gitops/clusters/{dev,prod}/application.yaml` valueFiles.
6. Updated `values.schema.json` for digest-related keys.

## Files Changed

**Templates:**
* `templates/_helpers.tpl` — `techx-corp.containerImage` helper.
* `templates/_objects.tpl` — main/sidecar image resolution.
* `templates/mem0.yaml` — mem0 image digest support.

**Overlays / GitOps:**
* `service-digest/README.md` — contract documentation.
* `service-digest/values-*.yaml` — 23 placeholder overlays.
* `gitops/clusters/dev/application.yaml` — valueFiles for service-digest.
* `gitops/clusters/prod/application.yaml` — valueFiles for service-digest.

**Schema:**
* `values.schema.json` — `digest`, `sidecarImageDigests` (JSON; no comment trail).

**Documentation:**
* `docs/changes/2026-07-20-service-digest-helm-overlays.md` — this record.

Change trail exception for `values.schema.json`: strict JSON has no comment syntax.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-20-cicd-service-digest-promote-hardening.md`
* Platform CI must write digests under `service-digest/` (companion change).
* No infra change required for Helm rendering; admission/Cosign policy remains separate.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Workloads pull by digest once overlays are populated; otherwise unchanged (tag) |
| **Infrastructure** | No change |
| **Deployment** | Argo loads 23 additional valueFiles (mostly empty until promote) |
| **Performance** | Negligible Helm merge cost |
| **Security** | Enables immutable digest deploy pins from signed ECR images |
| **Reliability** | Empty placeholders keep chart installable before first promote |
| **Backward compatibility** | Tag path remains default until digests exist |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-dev.yaml` | Pass |
| Digest render | `helm template` with temporary checkout/flagd digest overlays | Images rendered as `…@sha256:…` |

### Manual Verification

* Confirmed whitespace fix so `name`/`image` lines do not concatenate.
* Schema rejects invalid digest property names prior to schema update (expected).

### Remaining Verification (Post-Merge)

* After platform promote to dev: inspect `service-digest/values-*.yaml` and `argocd app wait techx-corp-dev`.
* Prod: merge digest PR and confirm Application sync.

## Migration or Deployment Notes

1. Merge this chart change to the branches Argo tracks (`techx-dev-corp` / `main`) **before or with** the first platform digest promote.
2. No manual value edits required for empty placeholders.
3. Do not delete listed service-digest valueFiles from Argo Application specs.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Bad digest pin fails pod pull | Low | High | Platform only writes verified ECR digests; revert overlay file |
| Argo valueFile path typo | Low | High | Lint + Application review |

**Rollback procedure:**

1. Revert this chart commit (templates, schema, Argo valueFiles, service-digest folder).
2. Workloads return to tag-only image references on next sync.

<!-- Change trail: @hungxqt - 2026-07-20 - Record chart service-digest Helm/GitOps overlays. -->
