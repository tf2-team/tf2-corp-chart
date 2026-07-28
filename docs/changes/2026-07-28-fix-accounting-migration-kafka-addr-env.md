# Change: Fix Missing KAFKA_ADDR and AWS_REGION Environment Variables in Accounting Chart & Migration Job

## Summary

Updated `templates/accounting-migration-job.yaml` to include the full component pod environment variable set (`{{- include "techx-corp.pod.env" $config | nindent 12 }}`) instead of hardcoding `DB_CONNECTION_STRING` alone. Also added `AWS_REGION` (`us-east-1`) to `accounting` configuration in `values-prod.yaml` and `values.yaml`. This supplies `KAFKA_ADDR`, `AWS_REGION`, and associated Kafka/MSK configuration to the `accounting` workload and `accounting-migration` PreSync Job pod, preventing `System.InvalidOperationException: The KAFKA_ADDR environment variable is not set.` and `AmazonClientException: No RegionEndpoint or ServiceURL configured` errors.

## Context

When the `accounting-migration` Job executed during Argo CD PreSync, the pod failed with unhandled exceptions due to missing environment variables (`KAFKA_ADDR` and `AWS_REGION`).

* Why is this change needed now? The PreSync migration job failed to start because `KAFKA_ADDR` and `AWS_REGION` were omitted from the job container environment.
* Decisions: Replaced hardcoded single-env entry in `templates/accounting-migration-job.yaml` with standard `techx-corp.pod.env` helper and configured `AWS_REGION` in chart values.

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

`KAFKA_ADDR` and `AWS_REGION` were not supplied to the migration Job pod.

## After

`templates/accounting-migration-job.yaml` uses the standard Helm helper for pod environment variables:

```yaml
env:
  {{- include "techx-corp.pod.env" $config | nindent 12 }}
```

In dev, `KAFKA_ADDR` renders as `kafka:9092` and `AWS_REGION` as `us-east-1`. In production (`values-prod.yaml`), `KAFKA_ADDR`, `KAFKA_TLS`, `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`, and `AWS_REGION` render properly.

## Technical Design Decisions

* **Use `techx-corp.pod.env` helper instead of adding `KAFKA_ADDR` manually:** Ensures full environment parity between the main `accounting` microservice deployment and the `accounting-migration` PreSync Job.
* **Explicit `AWS_REGION` in chart values:** Ensures DynamoDB client in OutboxReconciler has explicit AWS region context.

## Implementation Details

1. Modified `templates/accounting-migration-job.yaml` container `env` block to invoke `techx-corp.pod.env` for `$config`.
2. Added `AWS_REGION` (`us-east-1`) to `accounting.envOverrides` in `values-prod.yaml` and `accounting.env` in `values.yaml`.
3. Verified template rendering with `helm template` for both dev and production overlay configurations.

## Files Changed

**Templates & Values:**
* `templates/accounting-migration-job.yaml` — Updated container `env` block to use `techx-corp.pod.env`.
* `values-prod.yaml` — Added `AWS_REGION: us-east-1` to `accounting.envOverrides`.
* `values.yaml` — Added `AWS_REGION: us-east-1` to `accounting.env`.

**Documentation:**
* `docs/changes/2026-07-28-fix-accounting-migration-kafka-addr-env.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-28-fix-accounting-outbox-reconciler-dynamodb-region.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | `accounting-migration` PreSync Job has access to `KAFKA_ADDR`, `AWS_REGION`, and database credentials during execution. |
| **Infrastructure** | No change |
| **Deployment** | Argo CD PreSync migration job succeeds without environment missing errors. |
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
| Helm Template (Prod) | `helm template techx-corp ./techx-corp-chart --namespace techx-corp-prod -f ./techx-corp-chart/values-public-alb.yaml -f ./techx-corp-chart/values-prod.yaml -s templates/accounting-migration-job.yaml` | ✅ Pass (renders `KAFKA_ADDR`, `AWS_REGION`, `DB_CONNECTION_STRING`) |
| Helm Template (Dev) | `helm template techx-corp ./techx-corp-chart --namespace techx-corp-dev -s templates/accounting-migration-job.yaml` | ✅ Pass (renders `KAFKA_ADDR`, `AWS_REGION`, `DB_CONNECTION_STRING`) |

### Manual Verification

* Verified rendered YAML output contains `KAFKA_ADDR`, `AWS_REGION`, `DB_CONNECTION_STRING`, `KAFKA_TLS`, `KAFKA_SASL_USERNAME`, and `KAFKA_SASL_PASSWORD`.

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

<!-- Change trail: @hungxqt - 2026-07-28 - Add change document for accounting migration KAFKA_ADDR and AWS_REGION environment variable fix. -->
