# External Secrets Operator + AWS Secrets Manager (SEC-05)

Credentials live in **AWS Secrets Manager**. **ESO** syncs them into Kubernetes `Secret`s. Pods use `secretKeyRef` only. Terraform must never read, accept, or store token values, including in state, plans, outputs, or logs.

```
AWS Secrets Manager  ──(IRSA)──►  ESO  ──►  K8s Secret  ──►  Pod env
```

Full plan: workspace `docs/eso-aws-secrets-manager.md`.

---

## Deploy order (required)

1. Provision the replacement property in the existing ASM object through the approved out-of-band secret-entry process. Terraform must not read or store it.
2. Merge the `secrets-chart` Git change. Argo CD Applications **`techx-corp-secrets`** (prod) / **`techx-corp-secrets-dev`** (dev) auto-sync path `secrets-chart` into the app namespace.
3. Verify the `ExternalSecret` is Ready and that the generated Kubernetes `Secret` contains the required key name, without reading or printing its payload.
4. Merge the application chart reference to the generated Secret and let Argo CD sync the main app Application (`techx-corp` / `techx-corp-dev`).
5. Verify the replacement pods become Ready and flag synchronization succeeds.
6. Revoke the superseded token only after the replacement pods are healthy.

Never combine “source migration” and “password rotation” in one change.

### GitOps ownership (secrets-chart)

| Environment | Argo Application | Project | Path | Helm releaseName | Destination NS |
|-------------|------------------|---------|------|------------------|----------------|
| production | `techx-corp-secrets` | `techx-corp` | `secrets-chart` | `techx-corp-secrets` | `techx-corp-prod` |
| development | `techx-corp-secrets-dev` | `techx-corp-dev` | `secrets-chart` | `techx-corp-secrets` | `techx-corp-dev` |

Manifests: `gitops/clusters/{prod,dev}/secrets-application.yaml`.  
These are **not** part of the main app Application (`path: .`). After the secrets Application is bootstrapped, do **not** routine `helm upgrade` for `techx-corp-secrets`.

---

## Phase 1 — Terraform foundation

```bash
# development example
cd techx-corp-infra
terraform -chdir=environments/development apply

terraform -chdir=environments/development output secrets_manager_secret_names
terraform -chdir=environments/development output external_secrets_role_arn
terraform -chdir=environments/development output -raw external_secrets_helm_command
terraform -chdir=environments/development output -raw external_secrets_cluster_secret_store_manifest
```

Confirm state has **no** `secret_string` / `aws_secretsmanager_secret_version` for app passwords.

Optional: set `external_secrets_install_helm = true` and `external_secrets_create_cluster_secret_store = true` when the cluster API is reachable at apply time.

---

## Phase 2 — Bootstrap ASM (current live passwords)

**Use credentials already working on the cluster** (first cutover: often demo `root`/`otel`, `otelu`/`otelp`). Do **not** invent new DB passwords here.

Prefer the infra bootstrap scripts (same defaults and env overrides on both platforms).

Use the **full extension** (`.ps1` / `.cmd` / `.sh`). From `techx-corp-infra`:

**Windows CMD:**

```cmd
scripts\bootstrap-asm-secrets.cmd techx-corp/development us-east-1
REM production:
scripts\bootstrap-asm-secrets.cmd techx-corp/production us-east-1
```

**PowerShell:**

```powershell
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1
# production:
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/production us-east-1
```

**Bash / Git Bash / WSL:**

```bash
./scripts/bootstrap-asm-secrets.sh techx-corp/development us-east-1
# production:
./scripts/bootstrap-asm-secrets.sh techx-corp/production us-east-1
```

Override example (PowerShell):

```powershell
$env:PG_APP_PASSWORD = "otelp"
$env:OPENAI_API_KEY = "dummy"
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1
```

Manual `aws` equivalent (any shell):

```bash
PREFIX=techx-corp/development   # or techx-corp/production
REGION=us-east-1

aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/postgresql-admin" \
  --secret-string '{"username":"root","password":"otel","database":"otel"}'

aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/postgresql-app" \
  --secret-string '{"username":"otelu","password":"otelp","database":"otel"}'
```

The existing `<prefix>/flagd-ui` ASM object must have this JSON shape before the GitOps cutover:

```json
{"SECRET_KEY_BASE":"<existing-value>","FLAGD_SYNC_TOKEN":"<replacement-value>"}
```

Provision `FLAGD_SYNC_TOKEN` through the approved out-of-band secret-entry process. Do not pass it through Terraform variables, plans, state, outputs, or repository files.

The flagd cutover verification commands are presented in Windows CMD first in Phase 2c. No command here accepts or prints the token. The remaining manual bootstrap examples continue below for unrelated secret objects:

```bash
aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/product-reviews" \
  --secret-string '{"OPENAI_API_KEY":"dummy"}'

# Grafana: do NOT set admin-password to the literal string "admin".
# Grafana's login UI hardcodes a change-password interstitial when the typed
# password is "admin" (no grafana.ini flag disables that). Use a non-"admin" value.
aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/grafana" \
  --secret-string '{"admin-user":"admin","admin-password":"<ReplaceWithNonAdminPassword>"}'

# SEC-06: OpenSearch security plugin admin credentials
# OpenSearch requires: length >= 8, upper, lower, digit, AND special character.
# Prefer specials safe in JSON/shell: ! % ^ * _ - + = (avoid @ : / ? # ; space ' \ " $ `).
# Length >= 24 recommended. This bootstraps the built-in admin user on first node start.
# Do NOT use a password without a special character — bootstrap will reject it.
aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/opensearch" \
  --secret-string '{"username":"admin","password":"<StrongPassw0rd!ReplaceMe>"}'
```

For **OpenSearch only**, include a special character (OpenSearch security plugin rule). Other secrets that are DSN-concatenated should stay alphanumeric (avoid `@ : / ? # ; space ' \`).

---

## Phase 2b — Install ESO + ClusterSecretStore

```bash
# From techx-corp-infra
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Prefer Terraform output (pinned chart + IRSA role ARN)
terraform -chdir=environments/development output -raw external_secrets_helm_command
# Run the printed helm upgrade --install.
# Do not Ctrl+C or close the shell during --wait (can leave pending-install).

helm status external-secrets -n external-secrets
# expect STATUS: deployed  (not pending-install / pending-upgrade)

kubectl -n external-secrets get pods
# controller, cert-controller, webhook Ready 1/1

kubectl get sa external-secrets -n external-secrets -o yaml
# must include eks.amazonaws.com/role-arn

# ClusterSecretStore (JWT / IRSA)
terraform -chdir=environments/development output -raw external_secrets_cluster_secret_store_manifest | kubectl apply -f -

kubectl get clustersecretstore aws-secretsmanager
# STATUS should be Valid / Ready
```

### Helm stuck: `another operation is in progress`

```text
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

```bash
helm status external-secrets -n external-secrets
helm history external-secrets -n external-secrets --max 5
# Typical: STATUS pending-install while pods may already be Running

# Clear lock when install never reached deployed:
helm uninstall external-secrets -n external-secrets --wait --timeout 5m
terraform -chdir=environments/development output -raw external_secrets_helm_command
# re-run printed install; wait until STATUS: deployed
```

Do **not** start a second `helm upgrade` while STATUS is still `pending-*`.  
If a prior revision was `deployed` and only an upgrade is pending, try `helm rollback external-secrets <rev> -n external-secrets` first.

---

## Phase 2c — ExternalSecrets GitOps sync

### Bootstrap secrets Application (once per cluster)

Preferred: apply the **root** app-of-apps once so `secrets-application.yaml` under
`gitops/clusters/{env}/` is reconciled by Argo (same path as store + Gatekeeper apps).

```cmd
REM Prod
kubectl apply -f gitops\bootstrap\prod\
argocd app wait root-prod --sync --health --timeout 300
argocd app get techx-corp-secrets
argocd app wait techx-corp-secrets --sync --health --timeout 300

REM Dev
kubectl apply -f gitops\bootstrap\dev\
argocd app wait root-dev --sync --health --timeout 300
argocd app get techx-corp-secrets-dev
argocd app wait techx-corp-secrets-dev --sync --health --timeout 300
```

Break-glass (pre-root only): `kubectl apply -f gitops/clusters/{env}/secrets-application.yaml`
still works if the root Application is not installed yet.

### Ongoing mapping changes

Commit the `secrets-chart` mapping, merge it through the normal repository workflow, and let Argo CD reconcile Application `techx-corp-secrets` / `techx-corp-secrets-dev`. Do not run direct mutating Helm or kubectl commands against this Argo-managed release after cutover.

After Argo CD reports the sync healthy, use read-only checks. The second command prints key names only, never payloads.

```cmd
kubectl -n techx-corp-prod wait --for=condition=Ready externalsecret/techx-corp-flagd-ui --timeout=120s
kubectl -n techx-corp-prod get secret techx-corp-flagd-ui -o go-template="{{range $key, $value := .data}}{{println $key}}{{end}}"
```

The key-name output must include both `SECRET_KEY_BASE` and `FLAGD_SYNC_TOKEN`. Stop the cutover if the `ExternalSecret` is not Ready or either key is absent.

`creationPolicy: Orphan` — deleting ExternalSecret during experiments should not GC the K8s Secret (verify on pinned ESO version in dev).

### Argo CD sync status (ESO-generated Secrets)

Application `techx-corp-secrets` / `techx-corp-secrets-dev` must manage **only** `ExternalSecret` CRs. ESO creates the target Kubernetes `Secret`s.

**Do not** enable `prune: true` on the secrets Application to “clear” OutOfSync Secrets — that can delete live credential Secrets.

From chart `0.1.2`, every ExternalSecret `target` sets `template.engineVersion: v2` (with or without `template.data`). On ESO v0.14+, a present `template` means the operator **does not** copy ExternalSecret labels/annotations (including `argocd.argoproj.io/instance` and Helm metadata) onto the generated Secret. Empty `template.data` still materializes keys from `spec.data` / `dataFrom`.

After Argo syncs the ExternalSecret change, ESO re-reconciles and drops previously copied tracking labels from managed fields. Expected result:

```cmd
kubectl get application -n argocd techx-corp-secrets -o jsonpath="{.status.sync.status} {.status.health.status}{'\n'}"
REM expect: Synced Healthy

kubectl -n techx-corp-prod get secret techx-corp-flagd-ui -o jsonpath="{.metadata.labels}{'\n'}"
REM expect: reconcile.external-secrets.io/managed only (no argocd.argoproj.io/instance)
```

If a Secret still carries `argocd.argoproj.io/instance` after ExternalSecrets are Ready (stale labels not owned by ESO field manager), remove **only** the tracking label (not the Secret):

```cmd
kubectl -n techx-corp-prod label secret techx-corp-flagd-ui techx-corp-grafana-admin techx-corp-grafana-discord techx-corp-opensearch techx-corp-postgresql-admin techx-corp-product-reviews techx-corp-valkey-cart argocd.argoproj.io/instance-
```

Do not print Secret data while diagnosing sync status.

---

## Phase 3 — App chart GitOps cutover

Merge the `values-prod.yaml` `secretKeyRef` and placeholder only after Phase 2c confirms the generated Secret has `FLAGD_SYNC_TOKEN`. Let Argo CD reconcile the application release; do not use direct Helm upgrades, rollbacks, or mutating kubectl commands for this Argo-managed workload.

Use read-only checks to confirm the new pod revision is Ready and flagd remains healthy:

```cmd
kubectl -n techx-corp-prod get deployment flagd
kubectl -n techx-corp-prod get pods -l opentelemetry.io/name=flagd
kubectl -n techx-corp-prod logs deployment/flagd --tail=100
```

Do not print environment variables or Kubernetes Secret payloads during verification. Revoke the superseded token out-of-band only after the replacement pods are Ready and the remote flag source is synchronizing successfully.

### Local demo without ESO

```bash
helm upgrade --install techx-corp ./ \
  -n techx-corp-prod \
  -f values.yaml \
  -f values-demo.yaml
```

---

## Phase 5 — Password rotation (separate window)

Example app user:

```bash
# 1) Generate safe password (alphanumeric)
NEW_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)

# 2) Apply inside Postgres first
kubectl -n techx-corp-prod exec -it statefulset/postgresql -- \
  psql -U root -d otel -c "ALTER ROLE otelu WITH PASSWORD '${NEW_PASS}';"

# 3) Update ASM
aws secretsmanager put-secret-value --region us-east-1 \
  --secret-id techx-corp/production/postgresql-app \
  --secret-string "{\"username\":\"otelu\",\"password\":\"${NEW_PASS}\",\"database\":\"otel\"}"

# 4) Wait ESO
kubectl -n techx-corp-prod wait --for=condition=Ready externalsecret/techx-corp-postgresql-app --timeout=120s

# 5) Restart consumers through a reviewed Git chart change so Argo CD owns
#    reconciliation. Do not run kubectl rollout restart on managed Deployments.
#    After Argo sync, the read-only status check is:
kubectl -n techx-corp-prod rollout status deployment/accounting --timeout=300s

# 6) Smoke
./scripts/smoke-test.sh --namespace techx-corp-prod
```

Repeat pattern for admin / Grafana / flagd-ui as needed. After admin rotation, update residual OTel scrape annotation password or disable scrape.

---

## Residual risks (tracked)

| Item | Note |
|------|------|
| `postgresql/init.sql` ConfigMap | Still has `CREATE USER ... PASSWORD 'otelp'` for first boot only; harmless after PVC init |
| Postgres metrics scrape annotation | Still has scrape password; cannot secretKeyRef — follow-up |
| Dual-mode | Production path is ESO only; demo is `-f values-demo.yaml` |

---

## RBAC / IAM notes

- IAM: `GetSecretValue` + `DescribeSecret` on **exact ARNs** only (no `ListSecrets` by default)
- ClusterSecretStore is cluster-wide; limit who can create `ExternalSecret` / `ClusterSecretStore`
- No static AWS access keys in the store

---

## Rollback after cutover

- Revert the Git reference to the last known-good secret-backed configuration and let Argo CD reconcile it. Do not run a direct Helm rollback against the managed release.
- Keep ESO and the Kubernetes Secret in place while investigating.
- Never restore a literal, superseded, or revoked credential to Git. If the replacement token is invalid, issue another replacement out-of-band and repeat the ordered GitOps cutover.
- Local/demo only: `values-demo.yaml`

<!-- Change trail: @hungxqt - 2026-07-16 - Document ESO target.template to prevent Argo OutOfSync on generated Secrets. -->
