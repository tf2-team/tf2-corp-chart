# Change: Integrate LLM Observability Dimensions, Jaeger Routing, and Grafana Dashboard

## Summary

Extends Helm charts and Grafana configuration to support LLM Observability across `shopping-copilot` and `product-reviews`. OTel Collector configuration is extended with low-cardinality spanmetrics dimensions (`app.ai.surface`, `gen_ai.request.model`, `app.ai.outcome`, `gen_ai.operation.name`). The frontend deployment values are configured with `JAEGER_QUERY_URL` (`http://jaeger:16686`). `secrets-chart` is extended with an `ai-observability` ExternalSecret mapping `AI_OBSERVABILITY_HMAC_KEY` from Secrets Manager. NetworkPolicy is updated to allow frontend egress to Jaeger TCP 16686 and matching Jaeger ingress. A 5-panel Grafana dashboard (`UID: llm-observability`) and verification suite are provisioned.

## Context

Low-cardinality metric aggregations and private trace proxy capabilities required spanmetrics dimensions, network permissions, secret externalization, and operational dashboards.

## Before

* OTel Collector spanmetrics connectors lacked GenAI dimensions.
* Frontend lacked `JAEGER_QUERY_URL` environment configuration.
* NetworkPolicy blocked frontend egress to internal Jaeger on port 16686.
* `secrets-chart` had no `ExternalSecret` for `AI_OBSERVABILITY_HMAC_KEY`.
* No dedicated LLM Observability Grafana dashboard existed.

## After

* `values.yaml` and `values-aiops-long-run-1000.yaml` configure spanmetrics dimensions (`app.ai.surface`, `gen_ai.request.model`, `app.ai.outcome`, `gen_ai.operation.name`).
* `JAEGER_QUERY_URL` set to `http://jaeger:16686` in frontend deployment values.
* NetworkPolicy allows frontend egress to `jaeger:16686` and corresponding Jaeger ingress from `frontend`.
* `secrets-chart` targets and templates updated with `aiObservability` ExternalSecret mapping `AI_OBSERVABILITY_HMAC_KEY`.
* Provisioned Grafana dashboard `llm-observability.json` with 5 required PromQL panels (Tokens Stat, Cost Stat, P95 latency ms, Error rate %, Fallback rate ops/sec).
* Added PowerShell verification script `tests/observability/verify-llm-observability.ps1` and integrated into `.github/workflows/network-containment.yml`.

## Technical Design Decisions

* **Low-Cardinality Dimensions**: Added only approved 4 spanmetrics dimensions to keep metric cardinality bounded.
* **Orphan Creation Policy**: `secrets-chart` uses `creationPolicy: Orphan` to prevent secret garbage collection on chart rollout.

## Implementation Details

1. Updated `values.yaml` and `values-aiops-long-run-1000.yaml` spanmetrics connector config.
2. Added `JAEGER_QUERY_URL` to frontend env in `values.yaml`.
3. Extended `secrets-chart/values.yaml` and `secrets-chart/templates/externalsecrets.yaml` with `aiObservability` ExternalSecret.
4. Updated `templates/networkpolicy.yaml` ingress and egress rules for Jaeger port 16686.
5. Created `grafana/provisioning/dashboards/llm-observability.json`.
6. Created `docs/operations/llm-observability.md` and `tests/observability/verify-llm-observability.ps1`.
7. Updated `.github/workflows/network-containment.yml`.

## Files Changed

**Configuration & Values:**
* `values.yaml` — Configured spanmetrics dimensions and frontend `JAEGER_QUERY_URL`.
* `values-aiops-long-run-1000.yaml` — Configured spanmetrics dimensions.

**Secrets Chart:**
* `secrets-chart/values.yaml` — Added `aiObservability` target.
* `secrets-chart/templates/externalsecrets.yaml` — Rendered `ai-observability` ExternalSecret resource.

**Templates & Security:**
* `templates/networkpolicy.yaml` — Allowed frontend egress to `jaeger:16686` and matching jaeger ingress.

**Grafana & Operations:**
* `grafana/provisioning/dashboards/llm-observability.json` — Provisioned 5-panel LLM Observability dashboard. (Change trail exception: JSON format does not support comments).
* `docs/operations/llm-observability.md` — Operations runbook for LLM Observability.

**CI & Verification:**
* `tests/observability/verify-llm-observability.ps1` — Created PowerShell verification script.
* `.github/workflows/network-containment.yml` — Added `verify-llm-observability.ps1` gate step.

**Documentation:**
* `docs/changes/2026-07-29-integrate-llm-observability.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-29-integrate-llm-observability.md`
* Related: `techx-corp-infra/docs/changes/2026-07-29-protect-private-ai-traces.md`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Frontend can proxy trace queries to Jaeger; OTel Collector generates low-cardinality spanmetrics. |
| **Infrastructure** | Deploys new `ExternalSecret` for `techx-corp-ai-observability`. |
| **Deployment** | Requires `techx-corp-secrets` sync before application pod startup. |
| **Performance** | Zero impact on hot-path request latency. |
| **Security** | Jaeger 16686 egress strictly scoped to frontend pods; HMAC key managed via Secrets Manager and ESO. |
| **Reliability** | Low-cardinality spanmetrics dimensions prevent Prometheus TSDB cardinality explosion. |
| **Cost** | No infrastructure cost increase. |
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Adds 5-panel Grafana dashboard and PromQL metrics tracking. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Chart verification script | `powershell -ExecutionPolicy Bypass -File ./tests/observability/verify-llm-observability.ps1` | ✅ Pass |

## Migration or Deployment Notes

1. Deploy `techx-corp-secrets` chart first to materialize `techx-corp-ai-observability` K8s Secret.
2. Verify ExternalSecret readiness before syncing app chart.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| NetworkPolicy blocks trace lookup | Low | Medium | Verify NetworkPolicy allows `frontend` -> `jaeger:16686`. |

**Rollback procedure:**

Revert Git commit in `techx-corp-chart`.

<!-- Change trail: @hungxqt - 2026-07-29 - Configured LLM observability spanmetrics dimensions, Jaeger NetworkPolicy, secrets-chart ExternalSecret, and Grafana dashboard. -->
