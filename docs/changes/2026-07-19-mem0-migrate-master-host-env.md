# Change: Wire Mem0 migrate master host/port and APP_DB_NAME

## Summary

The Mem0 migrate Job failed after `psycopg` import succeeded because `bootstrap_rds_iam.py` requires `MEM0_RDS_MASTER_HOST` while the chart only set `POSTGRES_HOST`. The Job (and API/cleanup pods) now set `MEM0_RDS_MASTER_HOST`/`MEM0_RDS_MASTER_PORT` for bootstrap and `APP_DB_NAME` aligned with `mem0.rds.database` so Alembic/`db.py` do not fall back to the wrong default database name `mem0_app`.

## Context

Runtime error from the migrate Job:

```text
RuntimeError: MEM0_RDS_MASTER_HOST is required for RDS IAM bootstrap.
```

Forked Mem0 (`bootstrap_rds_iam.py`) connects as the RDS master with:

* `MEM0_RDS_MASTER_HOST` (required)
* `MEM0_RDS_MASTER_PORT` (default `5432`)
* `MEM0_RDS_MASTER_USERNAME` / `MEM0_RDS_MASTER_PASSWORD` (from ESO secret)
* `POSTGRES_DB` (target database for grants)

Alembic reuses `db.py`, which builds the URL with `APP_DB_NAME` (default `mem0_app`), not `POSTGRES_DB`. Production RDS database is `mem0` (`values-prod.yaml` → `mem0.rds.database`). Without `APP_DB_NAME`, migrations would target a non-existent DB after bootstrap.

Why now: production Mem0 cutover is blocked on migrate Job success.

## Before

Migrate Job env:

* `POSTGRES_HOST` / `POSTGRES_PORT` / `POSTGRES_DB` / `POSTGRES_USER`
* `envFrom` master secret → `MEM0_RDS_MASTER_USERNAME`, `MEM0_RDS_MASTER_PASSWORD` only
* No `MEM0_RDS_MASTER_HOST` / `MEM0_RDS_MASTER_PORT`
* No `APP_DB_NAME`

Deployment and cleanup CronJob also omitted `APP_DB_NAME`.

ExternalSecret comment incorrectly implied the app chart only needed `POSTGRES_HOST` for host/port.

## After

* Migrate Job sets `MEM0_RDS_MASTER_HOST`/`MEM0_RDS_MASTER_PORT` from `mem0.rds.host`/`port` (values, not ASM).
* Migrate Job, Deployment, and cleanup CronJob set `APP_DB_NAME` to `mem0.rds.database` (same as `POSTGRES_DB`).
* Existing master secret keys unchanged; host/port remain chart-owned (ESO does not map ASM `.host`/`.port`).
* Chart version `0.48.11`.

## Technical Design Decisions

* **Chosen:** map master host/port from chart values into `MEM0_RDS_*` env names expected by the bootstrap script. Matches intentional SEC-05 design (username/password from ASM; endpoint from values).
* **Rejected:** put host into the ESO template from ASM `host` property — RDS-managed secrets often omit host/port and ESO becomes not Ready (documented in secrets-chart).
* **Rejected:** change the Mem0 fork script to read `POSTGRES_HOST` — would work but couples bootstrap naming to local-dev env and requires a submodule pin bump; chart wiring is the faster, review-scoped fix.
* **Chosen:** set `APP_DB_NAME` everywhere SQLAlchemy/`db.py` may run so API and migrate stay on the same database as bootstrap grants.

## Implementation Details

1. Extended migrate Job env in `templates/mem0.yaml` with master host/port and `APP_DB_NAME`.
2. Added `APP_DB_NAME` to Deployment and cleanup CronJob env blocks.
3. Clarified secrets-chart ExternalSecret comments for master host ownership.
4. Bumped `Chart.yaml` to `0.48.11`.

## Files Changed

**Templates:**
* `templates/mem0.yaml` — `MEM0_RDS_MASTER_HOST`/`PORT` on migrate; `APP_DB_NAME` on migrate/API/cleanup.

**Secrets chart:**
* `secrets-chart/templates/externalsecrets.yaml` — Comment accuracy only (no data mapping change).

**Configuration:**
* `Chart.yaml` — Version `0.48.11`.

**Documentation:**
* `docs/changes/2026-07-19-mem0-migrate-master-host-env.md` — This change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-platform:** None for this chart env fix. Image must already include working `psycopg[binary]` (separate platform change).
* **techx-corp-infra:** None. RDS endpoint still comes from `values-prod.yaml` `mem0.rds.host`.
* **Mem0 submodule:** Contract unchanged; chart now matches script env names.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Bootstrap can open a master connection; Alembic targets DB `mem0` via `APP_DB_NAME` |
| **Infrastructure** | No change |
| **Deployment** | GitOps sync recreates migrate Job env; may need Force/Replace on existing failed Job (already annotated) |
| **Performance** | No change |
| **Security** | Master secret still migrate-only; host remains non-secret values |
| **Reliability** | Unblocks migrate Job past required-env failure |
| **Cost** | No change |
| **Backward compatibility** | Additive env vars; local/dev with `mem0.enabled: false` unaffected |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm template Mem0 | `helm template techx-corp . -n techx-corp-prod -f values.yaml -f values-public-alb.yaml -f values-prod.yaml --show-only templates/mem0.yaml` | Pending local helm if installed |
| Env grep | Rendered migrate env contains `MEM0_RDS_MASTER_HOST` and `APP_DB_NAME` | Pending template run |

### Manual Verification

* Confirmed bootstrap script source (pinned mem0 commit) requires `MEM0_RDS_MASTER_HOST`.
* Confirmed `db.py` uses `APP_DB_NAME` with default `mem0_app`.
* Confirmed ESO master secret only maps username/password.

### Remaining Verification (Post-Merge)

1. Argo sync app chart; confirm new migrate Job env includes master host.
2. Job logs: bootstrap succeeds, then `alembic upgrade head`.
3. Deployment readiness `/health/ready`.

## Migration or Deployment Notes

1. Merge/push this chart change (GitOps only; no direct `kubectl`/`helm upgrade` on auto-synced resources).
2. If a failed Job with the same name remains and does not replace, rely on existing annotations `argocd.argoproj.io/sync-options: Force=true,Replace=true`, or promote image tag so Job name suffix changes.
3. No secrets-chart data change required for this fix.

```cmd
cd /d techx-corp-chart
helm template techx-corp . -n techx-corp-prod ^
  -f values.yaml -f values-public-alb.yaml -f values-prod.yaml ^
  --show-only templates/mem0.yaml | findstr /C:"MEM0_RDS_MASTER" /C:"APP_DB_NAME"
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Alembic still fails (IAM grants / SG / IRSA) | Medium | High | Inspect Job logs after this env fix; separate from missing env |
| `APP_DB_NAME` mismatch if someone expects separate app DB name | Low | Medium | Keep equal to `mem0.rds.database` unless schema is split intentionally |

**Rollback procedure:**

1. Revert this commit (or remove the new env entries) and re-sync chart.
2. Chart version can be restored to `0.48.10` if required by release process.

<!-- Change trail: @hungxqt - 2026-07-19 - Document Mem0 migrate master host and APP_DB_NAME wiring. -->
