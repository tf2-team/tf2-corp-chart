# LLM Observability Operations Runbook

## Overview

The LLM Observability architecture provides end-to-end telemetry across `shopping-copilot` and `product-reviews` services without exposing raw prompts, responses, user IDs, or session IDs in OpenTelemetry spans or logs.

## Architecture & Data Flow

1. **Client Trace ID Header**: Next.js frontend middleware returns `x-trace-id` (32 lowercase hex characters) on `POST /api/copilot` and `POST /api/product-ask-ai-assistant/[productId]`.
2. **Private Trace Proxy**: Internal endpoint `GET /api/ai-traces/{traceId}` queries internal Jaeger (`http://jaeger:16686`) with 5s timeout, 5 MiB payload cap, and `Cache-Control: private, no-store`. Public edge (CloudFront) blocks `/api/ai-traces*`.
3. **HMAC Pseudonyms**: User and session IDs are pseudonymized using HMAC-SHA256 with key from `AI_OBSERVABILITY_HMAC_KEY` (minimum 32 bytes).
4. **Metrics**: Token usage and USD costs are emitted to Prometheus (`app_ai_model_tokens_total`, `app_ai_model_cost_usd_USD_total`). OTel Collector spanmetrics generates low-cardinality span metrics with dimensions `app.ai.surface`, `gen_ai.request.model`, `app.ai.outcome`, `gen_ai.operation.name`.
5. **Grafana Dashboard**: UID `llm-observability` renders 5 PromQL panels: Tokens Stat, Cost Stat, P95 latency ms TimeSeries, Error rate % TimeSeries, Fallback rate ops/sec TimeSeries.

## Troubleshooting & Verification

* **Verify Secret Ingestion**: Check Kubernetes Secret `techx-corp-ai-observability` key presence by name only.
* **Verify Private Route Isolation**: Confirm `curl -i http://<cloudfront-domain>/api/ai-traces/12345678901234567890123456789012` returns 403 Forbidden.
* **Verify Dashboard Rendering**: Open Grafana dashboard `LLM Observability` (`uid: llm-observability`).

<!-- Change trail: @hungxqt - 2026-07-29 - Created LLM Observability operations runbook. -->
