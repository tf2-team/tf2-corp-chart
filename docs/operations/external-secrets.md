# External Secrets Operator + AWS Secrets Manager (SEC-05)

Credentials live in **AWS Secrets Manager**. **ESO** syncs them into Kubernetes `Secret`s. Pods use `secretKeyRef` only. Terraform never stores secret *values*.

```
AWS Secrets Manager  ──(IRSA)──►  ESO  ──►  K8s Secret  ──►  Pod env
```

Full plan: workspace `docs/eso-aws-secrets-manager.md`.

---

## Deploy order (required)

1. Terraform: ASM secret **shells** + ESO IRSA (no values in state)
2. Bootstrap ASM with **currently live** credentials (`put-secret-value`)
3. Install ESO + `ClusterSecretStore` Ready
4. Helm release **`techx-corp-secrets`** → wait ExternalSecret Ready
5. Helm release **`techx-corp`** (app chart with `secretKeyRef`)
6. Smoke test

Never combine “source migration” and “password rotation” in one change.

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

**PowerShell (recommended on Windows):**

```powershell
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1
# production:
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/production us-east-1
```

**Windows CMD:**

```cmd
scripts\bootstrap-asm-secrets.cmd techx-corp/development us-east-1
REM production:
scripts\bootstrap-asm-secrets.cmd techx-corp/production us-east-1
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

aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/flagd-ui" \
  --secret-string '{"SECRET_KEY_BASE":"yYrECL4qbNwleYInGJYvVnSkwJuSQJ4ijPTx5tirGUXrbznFIBFVJdPl5t6O9ASw"}'

aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/product-reviews" \
  --secret-string '{"OPENAI_API_KEY":"dummy"}'

aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "${PREFIX}/grafana" \
  --secret-string '{"admin-user":"admin","admin-password":"admin"}'

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

## Phase 2c — ExternalSecrets release

```bash
cd techx-corp-chart

# --- Development ---
kubectl create namespace techx-corp-dev --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install techx-corp-secrets ./secrets-chart \
  -n techx-corp-dev \
  -f secrets-chart/values.yaml \
  -f secrets-chart/values-dev.yaml \
  --wait --timeout 5m
kubectl -n techx-corp-dev wait --for=condition=Ready externalsecret --all --timeout=120s
kubectl -n techx-corp-dev get secret \
  techx-corp-postgresql-admin \
  techx-corp-postgresql-app \
  techx-corp-flagd-ui \
  techx-corp-product-reviews \
  techx-corp-grafana-admin \
  techx-corp-opensearch

# --- Production ---
kubectl create namespace techx-corp-prod --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install techx-corp-secrets ./secrets-chart \
  -n techx-corp-prod \
  -f secrets-chart/values.yaml \
  -f secrets-chart/values-prod.yaml \
  --wait --timeout 5m
kubectl -n techx-corp-prod wait --for=condition=Ready externalsecret --all --timeout=120s
kubectl -n techx-corp-prod get secret \
  techx-corp-postgresql-admin \
  techx-corp-postgresql-app \
  techx-corp-flagd-ui \
  techx-corp-product-reviews \
  techx-corp-grafana-admin \
  techx-corp-opensearch
# Do not print secret values
```

`creationPolicy: Orphan` — deleting ExternalSecret during experiments should not GC the K8s Secret (verify on pinned ESO version in dev).

---

## Phase 3 — App chart (source cutover only)

```bash
# Development
helm upgrade --install techx-corp-dev ./ \
  -n techx-corp-dev \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-dev.yaml \
  --wait --atomic --timeout 15m
./scripts/smoke-test.sh --namespace techx-corp-dev

# Production
helm upgrade --install techx-corp ./ \
  -n techx-corp-prod \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-prod.yaml \
  --wait --atomic --timeout 15m
./scripts/smoke-test.sh --namespace techx-corp-prod
```

Expect no `CreateContainerConfigError`. Logs for accounting / product-catalog / product-reviews healthy.

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

# 5) Restart consumers (ESO does not refresh running pod env)
kubectl -n techx-corp-prod rollout restart deployment/accounting
kubectl -n techx-corp-prod rollout restart deployment/product-catalog
kubectl -n techx-corp-prod rollout restart deployment/product-reviews
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

- `helm rollback techx-corp` — keep ESO and K8s Secrets
- **Do not** re-introduce production passwords into Git
- Local/demo only: `values-demo.yaml`
