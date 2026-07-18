# Change: Mem0 production runtime with RDS IAM and ASM secrets

## Summary

Re-introduces a production-ready Mem0 self-hosted path on the app chart after PR #120 was reverted, with review fixes applied: correct image script paths, writable `/tmp` on batch jobs, FastEmbed S3 model delivery, tag-scoped migrate Jobs, ExternalSecrets owned by `secrets-chart` (SEC-05), parameterized AWS region, and tuned health probes. Production overlay enables Mem0 against existing RDS, IRSA, and ASM resources.

## Context

* PR #120 (`feature/mem0-rds-iam-deployment`) merged then was reverted via PR #126 after launch blockers were found.
* Platform already bakes a production Mem0 image (`WORKDIR /app/server`, FastEmbed offline cache at `/models/fastembed`) and can publish FastEmbed archives to the AI models bucket.
* Infra already provisions Mem0 RDS (IAM auth), AI model IRSA (`…-mem0-model-read`), and the S3 prefix `fastembed/paraphrase-multilingual-MiniLM-L12-v2/`.
* This change is required so AIE features can call an in-cluster Mem0 API without shipping the broken chart shape from #120.

## Before

* No Mem0 templates or values in the app chart (post-revert).
* No Mem0 ExternalSecrets in `secrets-chart`.
* Operators could not deploy Mem0 through GitOps without re-landing a fixed chart.

## After

* App chart renders (when `mem0.enabled`): ServiceAccount+IRSA, tag-scoped migrate Job, Deployment with optional FastEmbed dual-init, Service, cleanup CronJob.
* Secrets remain in `secrets-chart`: `techx-corp-mem0` (runtime) and `techx-corp-mem0-rds-master` (migrate-only).
* Production values supply RDS host, IRSA role, and FastEmbed `s3Prefix`/`archiveName` only — image and FastEmbed tag track `default.image.tag`.
* Chart version `0.48.10`.

## Technical Design Decisions

| Decision | Rationale | Rejected alternative |
|---|---|---|
| ExternalSecrets in `secrets-chart` only | SEC-05 ownership; secrets Application deploys before app | ES CRs in app chart (PR #120) |
| Job name includes image tag + Argo `Force/Replace` + TTL | Avoid immutable Job field failures on promote | Fixed name `mem0-migrate` |
| Dual init (aws-cli + busybox) for FastEmbed | Same split as product-reviews; aws-cli has no `tar` | Single init; HF egress at runtime |
| App chart consumes Secret **names** only | Decouples from ARNs; ARNs live in secrets overlay | Pass master/runtime ARNs into app values |
| Keep Mem0 as top-level `mem0:` values (not `components.*`) | Matches PR #120 shape; dedicated template with waves | Force into generic component template |
| Inherit `default.image.repository` + `default.image.tag` | Platform chart promote only rewrites `default.image.tag`; Mem0 is one of the 22 release images | Pinning `mem0.image.tag` (drifts on every promote) |
| Compose FastEmbed URI as `s3Prefix/tag/archiveName` | Same VERSION as image; CI retags FastEmbed under that tag | Full pinned `s3Uri` with a hard-coded sha |

**Known limitations**

* NetworkPolicy does not yet declare Mem0 east-west rules (same gap as #120); follow-up if NP is enforced for new services.
* Platform `MEM0_FASTEMBED_ARTIFACT_S3_URI` must equal Mem0 `modelDelivery.s3Prefix` (IRSA-allowed prefix) so CI publishes under `…/{{ tag }}/`.
* Runtime ASM JSON shape is not schema-enforced here; bootstrap remains an operator step.

## Implementation Details

1. Added `templates/mem0.yaml` with review fixes:
   * Commands use `scripts/...` relative to image `WORKDIR /app/server`.
   * Job and CronJob mount `emptyDir` at `/tmp` under `readOnlyRootFilesystem`.
   * Migrate Job name is `mem0-migrate-<image-tag>`; `ttlSecondsAfterFinished` and Argo Replace options set.
   * FastEmbed fetch/extract init containers when `modelDelivery.enabled`.
   * Probes include `startupProbe` plus explicit liveness/readiness thresholds.
   * Uvicorn CMD keeps `--no-access-log`.
2. Extended base `values.yaml` with disabled Mem0 defaults.
3. Production overlay enables Mem0 and supplies RDS/IRSA/modelDelivery prefix (no per-service image tag).
4. Registered Mem0 in `values.schema.json` (`s3Prefix`, `archiveName`, optional `s3Uri` override).
5. Extended `secrets-chart` values + template for optional Mem0 ExternalSecrets (prod enabled).
6. Bumped chart version to `0.48.10`.
7. Image resolution: `mem0.image.*` empty → `default.image.repository/mem0:default.image.tag`.

## Files Changed

**Templates:**
* `templates/mem0.yaml` — New Mem0 ServiceAccount, Job, Deployment, Service, CronJob.

**Configuration:**
* `values.yaml` — Disabled-by-default Mem0 block.
* `values-prod.yaml` — Production enablement and wiring.
* `values.schema.json` — Mem0 schema properties.
* `Chart.yaml` — Version `0.48.10`.

**Secrets chart:**
* `secrets-chart/values.yaml` — Targets + disabled mem0 remote keys.
* `secrets-chart/values-prod.yaml` — Enable Mem0 runtime/master remote keys.
* `secrets-chart/templates/externalsecrets.yaml` — Mem0 ExternalSecret CRs.

**Documentation:**
* `docs/changes/2026-07-18-mem0-rds-iam-production-runtime.md` — This change record.

Change trail exception for `values.schema.json`: JSON does not support comments.

## Dependencies and Cross-Repository Impact

* **techx-corp-infra:** Requires existing Mem0 RDS, IRSA role `techx-prod-tf2-mem0-model-read`, and AI models bucket prefix. No infra code change in this commit.
* **techx-corp-platform:** Requires Mem0 image tag and FastEmbed artifact published under the matching S3 prefix. Align `MEM0_FASTEMBED_ARTIFACT_S3_URI` with infra IRSA prefix `fastembed/paraphrase-multilingual-MiniLM-L12-v2`.
* **Order:** secrets Application Ready (Mem0 ES) → app chart sync (migrate wave 1 → Deployment wave 2).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | New in-cluster Mem0 API Service `mem0:8000` when enabled |
| **Infrastructure** | Consumes existing RDS + IRSA + ASM; no new TF resources in this change |
| **Deployment** | Argo auto-sync will apply Mem0 when this merges to the tracked branch; secrets-chart must sync first |
| **Performance** | One extra Deployment + daily cleanup CronJob; FastEmbed init on each pod start |
| **Security** | IRSA least-privilege for S3 model prefix + RDS IAM auth; master secret only on migrate Job |
| **Reliability** | Startup probe + tag-scoped migrate Job reduce first-boot and promote failure modes vs #120 |
| **Cost** | Small additional RDS traffic + S3 GetObject on pod start + one API pod |
| **Backward compatibility** | Fully additive; disabled unless overlay enables Mem0 |
| **Observability** | Labels/component `mem0` on workloads for selection; no new dashboards |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (prod path) | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Pass |
| Helm template Mem0 only | `helm template … --show-only templates/mem0.yaml` | Pass — image `…/mem0:{{ default.image.tag }}`, Job `mem0-migrate-<tag>`, FastEmbed URI `s3Prefix/<tag>/archive`, `scripts/*` paths |
| Secrets chart template | `helm template techx-corp-secrets ./secrets-chart -f secrets-chart/values.yaml -f secrets-chart/values-prod.yaml` | Pass — `techx-corp-mem0` + `techx-corp-mem0-rds-master` |
| Schema JSON parse | `python -c "import json; json.load(…)"` | Pass |

### Manual Verification

* Confirmed image contract: `WORKDIR /app/server`, scripts under `scripts/`, FastEmbed path `/models/fastembed`.
* Diffed against PR #120 and applied review findings (paths, `/tmp`, model delivery, Job name, secrets ownership).

### Remaining Verification (Post-Merge)

1. Confirm FastEmbed objects exist at the prod `s3Uri` (or re-publish under IRSA prefix).
2. Confirm ASM runtime secret `techx-corp/production/mem0` exists and ExternalSecrets are Ready.
3. Argo sync secrets Application, then app Application.
4. `kubectl -n techx-corp-prod get job,deploy,po -l app.kubernetes.io/component=mem0` (and migrate/cleanup labels).
5. Check migrate Job logs, then Deployment Ready and `/health/ready` via Service.

## Migration or Deployment Notes

1. **Pre-deploy**
   * Ensure platform FastEmbed artifact exists at `{{ s3Prefix }}/{{ default.image.tag }}/{{ archiveName }}` (and `.sha256`).
   * Ensure ASM secret for Mem0 runtime keys exists at `techx-corp/production/mem0`.
   * Confirm RDS endpoint and master secret ARN still match `secrets-chart/values-prod.yaml` and `values-prod.yaml`.
2. **Deploy order (GitOps)**
   1. Merge this chart change.
   2. Wait for `techx-corp-secrets` sync + Mem0 ExternalSecrets Ready.
   3. Wait for app Application: migrate Job wave 1 completes, Deployment wave 2 becomes Ready.
3. **Post-deploy**
   * Smoke: port-forward or in-cluster call to Mem0 health endpoints; optional memory add/search.
4. **Image promote**
   * Only `default.image.tag` (platform chart promote). Mem0 image and FastEmbed path follow automatically; ensure FastEmbed objects exist under the new tag prefix.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| FastEmbed object missing at s3Uri | Medium | High | Init fails closed; publish artifact or set `modelDelivery.enabled: false` only with offline cache present |
| Runtime ASM shape incomplete | Medium | High | ES Ready but app crash; fix ASM JSON and refresh |
| Migrate Job fails (IAM/network) | Medium | High | Inspect Job logs; fix SG/IAM; re-sync after tag bump creates new Job name |
| Argo applies Mem0 before secrets Ready | Low | Medium | Wave 0 on ES; app secretRef fails until Ready — re-sync |

**Rollback procedure:**

1. Set `mem0.enabled: false` in `values-prod.yaml` and `mem0.enabled: false` in `secrets-chart/values-prod.yaml`, or revert this commit.
2. Push to the GitOps branch and wait for Argo prune/sync.
3. Optionally delete leftover Jobs: `kubectl -n techx-corp-prod delete job -l app.kubernetes.io/component=mem0-migrate`.

<!-- Change trail: @hungxqt - 2026-07-18 - Document Mem0 global image tag inheritance and FastEmbed s3Prefix. -->
