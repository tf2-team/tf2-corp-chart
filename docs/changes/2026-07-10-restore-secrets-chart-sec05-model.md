# Change: Restore secrets-chart SEC-05 model after main merge

## Context

Merging `origin/main` into `techx-dev-corp` imported an alternate SEC-05 design (in-chart `ExternalSecret`s + ESO subchart + `techx-tf2` secret schema). That design conflicted with the monorepo path already used on this branch and in `techx-corp-infra`: separate `secrets-chart` release, ASM names under `techx-corp/{development,production}`, ClusterSecretStore `aws-secretsmanager`, and K8s Secrets named `techx-corp-*`.

The pre-merge branch tip (`dda1010`) had consistent `secretKeyRef` wiring. The merge also replaced the `metrics-server` Chart dependency with `external-secrets`, breaking the HPA packaging path while leaving `metrics-server` values and GitOps AppProject allowances in place.

## Before

- App chart `values.yaml` mixed main secret names (`app-db-credentials`, `postgres-credentials`, `flagd-ui-secret`, `grafana-admin`) with residual `techx-corp-postgresql-admin` / `techx-corp-product-reviews` refs.
- `templates/external-secrets.yaml` created a second secret model (wrong ASM layout vs Terraform).
- `Chart.yaml` depended on `external-secrets`; `Chart.lock` / local packaging still assumed `metrics-server`.
- Helm template failed: missing `external-secrets` package under `charts/`.

## After

- Reapplied the `dda1010` SEC-05 concept on the current branch:
  - Sensitive env uses `secretKeyRef` → `techx-corp-*` Secrets produced by `secrets-chart`.
  - App chart does **not** install ESO or own ExternalSecrets; infra + `secrets-chart` remain the source of secrets.
  - `metrics-server` is again the Chart dependency for HPA metrics.
- Non-conflicting post-merge work (GitOps auto-sync, OpenSearch ECR image, REL-06 resources, image tags, etc.) is preserved.

## Implementation

1. Restored `Chart.yaml` dependency: `metrics-server` 3.13.1 (condition `metrics-server.enabled`).
2. Restored `values.yaml` SEC-05 header and refs to match secrets-chart targets:
   - `techx-corp-postgresql-app` / DSN keys
   - `techx-corp-postgresql-admin` / `POSTGRES_*`
   - `techx-corp-flagd-ui` / `SECRET_KEY_BASE`
   - `techx-corp-product-reviews` / `OPENAI_API_KEY`
   - Grafana `existingSecret: techx-corp-grafana-admin`
3. Removed main-path `templates/external-secrets.yaml` and `scripts/create-secrets.sh` (ASM bootstrap remains via `techx-corp-infra` scripts + ops runbook).
4. Aligned `Chart.lock` with the metrics-server dependency set.

## Files Changed

* `Chart.yaml`
  * Swapped `external-secrets` dependency back to `metrics-server`.
* `Chart.lock`
  * Locked metrics-server dependency set again.
* `values.yaml`
  * Restored secrets-chart-aligned `externalSecrets` metadata and all production secretKeyRefs / Grafana existingSecret; residual Postgres scrape annotation password restored as documented residual risk.
* `templates/external-secrets.yaml`
  * Deleted (in-app ExternalSecrets no longer used).
* `scripts/create-secrets.sh`
  * Deleted (main ASM schema; infra bootstrap is canonical).
* `docs/changes/2026-07-10-restore-secrets-chart-sec05-model.md`
  * This change record.

## Impact

* **Application behavior:** Pods again expect K8s Secrets named `techx-corp-*` from the secrets release. Wrong if only main-style secrets were deployed.
* **Security:** Credentials still not stored in Git; sync path is ESO → secrets-chart → secretKeyRef.
* **Deployment:** Required order is ESO + ClusterSecretStore → `techx-corp-secrets` → app chart (see `docs/operations/external-secrets.md`).
* **Reliability:** Metrics Server subchart available again for HPA when `metrics-server.enabled: true`.
* **Backward compatibility:** Incompatible with main’s in-chart ExternalSecret resource names if those were applied in-cluster.

## Validation

```bash
helm dependency build .
helm template techx-corp-dev . \
  -f values.yaml -f values-public-alb.yaml -f values-dev.yaml \
  --namespace techx-corp-dev

helm template techx-corp-secrets ./secrets-chart \
  -f secrets-chart/values.yaml -f secrets-chart/values-dev.yaml \
  --namespace techx-corp-dev
```

Confirmed rendered app manifests reference only `techx-corp-*` secrets, include `metrics-server` and HPAs, and do not emit app-chart `ExternalSecret` / `ClusterSecretStore`. Secrets-chart renders targets matching those refs under prefix `techx-corp/development`.

## Migration or Deployment Notes

1. Do not deploy main-path secrets (`postgres-credentials`, `app-db-credentials`, …) for this branch.
2. Ensure ASM shells match infra (`postgresql-admin`, `postgresql-app`, `flagd-ui`, `product-reviews`, `grafana`) under `techx-corp/development` or `techx-corp/production`.
3. Deploy/upgrade `techx-corp-secrets` and wait ExternalSecrets Ready before app sync.
4. If a cluster already has Metrics Server cluster-wide, set `metrics-server.enabled: false` in the env overlay.

## Risks and Rollback

* Risk: operators following main ADR/`create-secrets.sh` flow will create the wrong ASM keys. Prefer `docs/operations/external-secrets.md` and infra bootstrap scripts.
* Residual: Postgres OTel scrape password remains in pod annotation (cannot use secretKeyRef); tracked residual.
* Rollback: re-introduce main’s in-chart ESO path only with a full rename of values, infra secrets, and deploy order (not a simple revert of one file).
* To undo this change only: `git checkout` the pre-fix versions of the listed files from the merge commit.
