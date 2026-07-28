# Change: Fix Missing KAFKA_ADDR Environment Variable in Accounting PreSync Migration Job

## Summary

Updated `templates/accounting-migration-job.yaml` to include the full component pod environment variable set (`{{- include "techx-corp.pod.env" $config | nindent 12 }}`) instead of hardcoding `DB_CONNECTION_STRING` alone. This supplies `KAFKA_ADDR` and associated Kafka/MSK configuration to the `accounting-migration` PreSync Job pod, preventing `System.InvalidOperationException: The KAFKA_ADDR environment variable is not set.` crashes.

## Context

When the `accounting-migration` Job executed during Argo CD PreSync, the pod failed with an unhandled exception:
`Unhandled exception. System.InvalidOperationException: The KAFKA_ADDR environment variable is not set.` at `Accounting.Consumer..ctor`.

* Why is this change needed now? The PreSync migration job failed to start because `KAFKA_ADDR` was omitted from the job's container `env` specification.
* Decisions: Replaced hardcoded single-env entry in `templates/accounting-migration-job.yaml` with standard `techx-corp.pod.env` helper to ensure all component environment variables (including MSK secret references and database credentials) are inherited consistently across deployments and jobs.

## Before

`templates/accounting-migration-job.yaml` explicitly configured only `DB_CONNECTION_STRING` in `env`:

```yaml
env:
  - name: DB_CONNECTION_STRING
    valueFrom:
      secretKeyRef:
        name: techx-corp-postgresql-app
        key: accounting-db-connection-string
```

`KAFKA_ADDR` and MSK TLS/SASL environment variables were not present in the Job template.

## After

`templates/accounting-migration-job.yaml` uses the standard Helm helper for pod environment variables:

```yaml
env:
  {{- include "techx-corp.pod.env" $config | nindent 12 }}
```

In dev, `KAFKA_ADDR` renders as `kafka:9092`. In production (`values-prod.yaml`), `KAFKA_ADDR`, `KAFKA_TLS`, `KAFKA_SASL_USERNAME`, and `KAFKA_SASL_PASSWORD` render from the `techx-corp-msk` secret.

## Technical Design Decisions

* **Use `techx-corp.pod.env` helper instead of adding `KAFKA_ADDR` manually:** Ensures full environment parity between the main `accounting` microservice deployment and the `accounting-migration` PreSync Job, avoiding future missing-variable drift.
* **Keep `--migrate-only` argument intact:** The container continues executing database migrations on startup.

## Implementation Details

1. Modified `templates/accounting-migration-job.yaml` container `env` block to invoke `techx-corp.pod.env` for `$config`.
2. Verified template rendering with `helm template` for both dev and production overlay configurations.

## Files Changed

**Templates:**
* `templates/accounting-migration-job.yaml` — Updated container `env` block to use `techx-corp.pod.env`.

**Documentation:**
* `docs/changes/2026-07-28-fix-accounting-migration-kafka-addr-env.md` — This change record.

## Dependencies and Cross-Repository Impact

None. The change is fully contained within `techx-corp-chart`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | `accounting-migration` PreSync Job has access to `KAFKA_ADDR` and database credentials during execution. |
| **Infrastructure** | No change |
| **Deployment** | Argo CD PreSync migration job succeeds without `KAFKA_ADDR` missing errors. |
| **Performance** | No change |
| **Security** | Secret references for MSK and PostgreSQL are preserved via Kubernetes Secret key refs. |
| **Reliability** | Eliminates PreSync job startup failures caused by missing environment variables. |
| **Cost** | No change |
| **Backward compatibility** | Fully backward-compatible |
| **Observability** | Retains OpenTelemetry exporter environment variables in job pod. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm Template (Prod) | `helm template techx-corp ./techx-corp-chart --namespace techx-corp-prod -f ./techx-corp-chart/values-public-alb.yaml -f ./techx-corp-chart/values-prod.yaml -s templates/accounting-migration-job.yaml` | ✅ Pass (renders `KAFKA_ADDR` from `techx-corp-msk`) |
| Helm Template (Dev) | `helm template techx-corp ./techx-corp-chart --namespace techx-corp-dev -s templates/accounting-migration-job.yaml` | ✅ Pass (renders `KAFKA_ADDR: kafka:9092`) |

### Manual Verification

* Verified rendered YAML output contains `KAFKA_ADDR`, `DB_CONNECTION_STRING`, `KAFKA_TLS`, `KAFKA_SASL_USERNAME`, and `KAFKA_SASL_PASSWORD`.

### Remaining Verification (Post-Merge)

* Verify Argo CD PreSync sync execution in cluster.

## Migration or Deployment Notes

None. Auto-synced by Argo CD upon commit.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| PreSync Job fails if `techx-corp-msk` secret does not exist in cluster | Low | Medium | Standard secret prerequisite; managed by ESO/ExternalSecrets in cluster. |

**Rollback procedure:**

Revert commit in `techx-corp-chart`.

<!-- Change trail: @hungxqt - 2026-07-28 - Add change document for accounting migration KAFKA_ADDR environment variable fix. -->
