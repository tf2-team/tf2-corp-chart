# Change: Managed-store collector receivers for AIOps RCA metrics (Valkey promote + RDS PostgreSQL)

## Summary

The AIOps/RCA detector reported `missing_metrics` (request_rate, cpu, socket_io) for `valkey-cart`, `postgresql`, and `kafka` because the Directive-08 cutover moved those stores to AWS managed services and the in-cluster pods (and their metric sources) were disabled. This change makes the engine-level metrics permanently collectable from the in-cluster Prometheus: the `redis/valkey-cart` OpenTelemetry Collector receiver is promoted from the temporary AIOps long-run overlay into `values-prod.yaml`, a new `postgresql/rds` receiver is added against the RDS instance, and the otel-collector egress NetworkPolicy now allows 5432 inside the VPC. A companion operations doc records the dedup-safe PromQL query pack for the RCA tool.

## Context

- Production PostgreSQL/Valkey/Kafka run as RDS `techx-prod-tf2-postgresql`, ElastiCache `techx-prod-tf2-cart`, and MSK `techx-prod-tf2-msk` (see `docs/operations/directive-08-managed-data-cutover.md`). `components.{postgresql,valkey-cart,kafka}.enabled: false` in `values-prod.yaml`.
- The old in-cluster PostgreSQL metrics came from annotation-discovery scraping of the postgresql pod (`values.yaml` `components.postgresql.podAnnotations`), which died with the pod. No PostgreSQL series existed in Prometheus at all.
- Valkey `redis_*` series existed only via `values-aiops-long-run-1000.yaml`, a profile documented as temporary (`docs/changes/2026-07-26-aiops-long-run-1000-capacity.md`) — the RCA metric set would disappear at overlay removal.
- MSK `kafka_*` series were already permanent (`kafkametrics` receiver in `values-prod.yaml`).
- Related follow-up (separate change): YACE CloudWatch exporter for host-level CPU/network metrics of all three managed stores.

## Before

- `values-prod.yaml` collector config: receivers `kafkametrics` (MSK) only; no `service.pipelines` override (base list `[otlp, kafkametrics, spanmetrics]` applied); extraEnvs OpenSearch + MSK only.
- `values-aiops-long-run-1000.yaml`: full `redis/valkey-cart` receiver definition (endpoint, password, 1s, TLS) + pipeline receivers `[otlp, kafkametrics, spanmetrics, redis/valkey-cart]` + `VALKEY_PASSWORD` env.
- `templates/networkpolicy.yaml` otel-collector-egress vpcCidr ports: 10250, 9096, 6379 (6379 commented "Delete after test done").
- Prometheus: no `postgresql_*` series; `redis_*` series present only while the overlay is applied.

## After

- `values-prod.yaml` owns both managed-store receivers:
  - `redis/valkey-cart` → `master.techx-prod-tf2-cart.2bnsjq.use1.cache.amazonaws.com:6379`, TLS, `VALKEY_PASSWORD` from ESO secret `techx-corp-valkey-cart`, 30s steady-state interval.
  - `postgresql/rds` → `techx-prod-tf2-postgresql.cijoii00i7pl.us-east-1.rds.amazonaws.com:5432`, TLS (`insecure_skip_verify: true`, matching the apps' `sslmode=require` posture), credentials `POSTGRES_MON_USER/PASSWORD/DB` from ESO secret `techx-corp-postgresql-app` (keys `username`/`password`/`database`), 60s interval.
  - `service.pipelines.metrics.receivers: [otlp, kafkametrics, spanmetrics, redis/valkey-cart, postgresql/rds]` restated in full (Helm replaces arrays).
- `values-aiops-long-run-1000.yaml` now only overrides `redis/valkey-cart.collection_interval: 1s`, restates the (extended) pipeline receivers array, and restates extraEnvs including the three new `POSTGRES_MON_*` entries.
- `templates/networkpolicy.yaml` otel-collector-egress vpcCidr ports: 10250, 9096, 6379 (comment updated — permanent), 5432 (new).
- Prometheus (after Argo sync) gains `postgresql_backends`, `postgresql_commits`, `postgresql_rollbacks`, `postgresql_db_size`, `postgresql_blocks_read`, etc., with the `postgresql_database_name` label (already in `prometheus.server.otlp.promote_resource_attributes`); `redis_*` series survive overlay removal.

## Technical Design Decisions

- **Hardcoded RDS endpoint in values**: the ESO-materialized secret `techx-corp-postgresql-app` templates exactly 6 keys (username, password, database, 3 DSN strings) — `rds_host`/`rds_port` are template variables, not output keys. Hardcoding mirrors the accepted ElastiCache precedent (`VALKEY_TLS_HOST`, receiver endpoint). Alternative (emitting rds_host/rds_port keys from the secrets-chart template) was rejected to keep this change chart-only and consistent.
- **Reuse app credentials** instead of a dedicated `pg_monitor` user: zero manual AWS/SQL steps; the app role can read the pg_stat views needed by the receiver for its database. A least-privilege `otel_monitor` user remains a possible follow-up (needs SQL grant + ASM entry + ExternalSecret key).
- **`insecure_skip_verify: true`**: RDS enforces TLS (`rds.force_ssl=1`); application DSNs use `sslmode=require` without CA pinning. The receiver mirrors that posture. CA pinning (RDS CA bundle mount) is a possible hardening follow-up.
- **60s interval for postgresql**: the collector is a DaemonSet; every agent (one per node) opens its own connection each cycle. 60s keeps RDS stats-query load trivial. Same reason the redis receiver is 30s in prod (the overlay may still run 1s during approved collection windows).
- **Known limitation — per-agent duplication**: like `kafkametrics` and `redis/valkey-cart`, the `postgresql/rds` receiver runs on every DaemonSet agent, so each series exists once per node. Consumers must aggregate with `max()`/`avg()` (never bare `sum()`); documented in `docs/operations/aiops-managed-store-queries.md`.
- **Pipeline array restated, not merged**: Helm replaces arrays in overlays; both `values-prod.yaml` and the AIOps overlay carry the full receiver list and must stay in sync while both are applied. When the overlay is removed per its own change doc, the prod list stands alone.

## Implementation Details

1. `templates/networkpolicy.yaml`: added `- { protocol: TCP, port: 5432 }` to the otel-collector-egress vpcCidr rule after 9096/6379 (the mandate-17 CI regex requires 10250 immediately followed by 9096; trailing ports are safe). Reworded the 6379 comment (receiver now permanent).
2. `values-prod.yaml`: appended `VALKEY_PASSWORD` + `POSTGRES_MON_USER/PASSWORD/DB` to collector `extraEnvs`; added `redis/valkey-cart` (30s) and `postgresql/rds` (60s) under `config.receivers`; added `config.service.pipelines.metrics.receivers` restating the full five-receiver list.
3. `values-aiops-long-run-1000.yaml`: appended the three `POSTGRES_MON_*` extraEnvs (array restatement); reduced its `redis/valkey-cart` block to the 1s interval override (endpoint/password/TLS now inherited from prod via map merge); extended its pipeline receivers list with `postgresql/rds`; added the missing change-trail comment.
4. New `docs/operations/aiops-managed-store-queries.md`: RCA query pack (see that file).

## Files Changed

**Templates:**
* `templates/networkpolicy.yaml` — otel-collector egress: +5432 (RDS), 6379 comment updated.

**Configuration:**
* `values-prod.yaml` — collector extraEnvs (+4), receivers `redis/valkey-cart` + `postgresql/rds`, full metrics-pipeline receiver list.
* `values-aiops-long-run-1000.yaml` — extraEnvs (+3 POSTGRES_MON_*), redis receiver reduced to interval override, pipeline list extended, change-trail added.

**Documentation:**
* `docs/operations/aiops-managed-store-queries.md` — RCA query pack for managed stores (new).
* `docs/changes/2026-07-26-managed-store-metrics-receivers.md` — this change record.

## Dependencies and Cross-Repository Impact

* None for this change itself (chart-only; secrets and network reachability already exist: ESO secrets `techx-corp-valkey-cart` / `techx-corp-postgresql-app` are synced, and the RDS/ElastiCache security groups already admit the EKS cluster SG).
* Related planned follow-up: `techx-corp-infra/docs/changes/2026-07-26-yace-cloudwatch-read-irsa.md` and `docs/changes/2026-07-26-yace-cloudwatch-exporter.md` (CloudWatch exporter for host-level CPU/network metrics).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change to storefront services; collector-only. |
| **Infrastructure** | No change (SG ingress from EKS cluster SG already covers 5432/6379). |
| **Deployment** | Argo CD auto-syncs on merge; collector DaemonSet pods restart on ConfigMap change. |
| **Performance** | ~17 extra RDS connections/min (one per agent, 60s interval) and ~34 ElastiCache INFO calls/min (30s) — negligible for both engines. |
| **Security** | Collector egress widened by one port (5432) inside the VPC only; DB creds reuse an existing ESO secret; no secrets in Git. |
| **Reliability** | Receiver failures degrade to missing metrics only; pipelines are independent of trace/log flow. |
| **Cost** | None. |
| **Backward compatibility** | Fully backward-compatible; overlay continues to work (arrays kept in sync). |
| **Observability** | Restores PostgreSQL engine metrics; makes Valkey metrics permanent; enables RCA `request_rate` queries for all three managed stores. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Dependency build | `helm dependency build .` | ✅ Pass |
| Lint + schema | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | ✅ Pass |
| Rendered manifests (CI gate) | `pwsh ./tests/mandate17/verify-rendered-manifests.ps1` | ✅ Pass |
| Render inspection (prod) | `helm template … -f values-prod.yaml` | ✅ Both receivers + full pipeline present |
| Render inspection (prod+overlay) | `helm template … -f values-aiops-long-run-1000.yaml` | ✅ redis 1s override merges; pipeline intact |

### Manual Verification

* Confirmed rendered otel-collector ConfigMap contains `redis/valkey-cart` and `postgresql/rds` with base processors/exporters intact in both render variants.
* Confirmed rendered `otel-collector-egress` NetworkPolicy lists 10250, 9096, 6379, 5432 in order.

### Remaining Verification (Post-Merge)

* After Argo sync: `kubectl -n techx-corp-prod logs ds/otel-collector-agent` shows no postgresql/redis receiver auth or TLS errors (operator).
* Prometheus returns series for `postgresql_backends` and `redis_commands_per_second` (operator; see query pack doc).

## Migration or Deployment Notes

1. Merge → Argo CD auto-syncs; no operator pre-steps (secrets and SG reachability already in place).
2. Post-sync verification per above.
3. When the AIOps long-run overlay is later removed (its own change doc), no action needed here — prod owns the receivers.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| RDS auth failure (app user lacks pg_stat access for the configured DB) | Low | Low | Metrics-only impact; check agent logs; fall back to dedicated monitor user follow-up |
| Extra RDS connections from 17 agents alarm connection monitoring | Low | Low | 60s interval keeps ≤17 conns/min; raise interval if needed |
| Array desync between values-prod and overlay | Low | Medium | Comments in both files; CI render check catches missing receivers |

**Rollback procedure:**

`git revert` this commit and merge; Argo CD reconciles the collector ConfigMap and NetworkPolicy to the prior state. No state is persisted by the receivers.

<!-- Change trail: @hungxqt - 2026-07-26 - Record managed-store receiver promotion and RDS scrape enablement. -->
