# Request-Metric HPA (Prometheus Adapter)

Hot-path services scale on **requests per second (RPS)** in addition to CPU/memory. Metrics come from OTel → Prometheus → **Prometheus Adapter** → HPA External metrics.

## Architecture

```text
App / auto-instrumentation (OTel)
  → OTel Collector (OTLP + spanmetrics)
  → Prometheus (OTLP receiver)
  → Prometheus Adapter (external metric: http_requests_per_second)
  → HorizontalPodAutoscaler (External AverageValue + Resource CPU/mem)
  → Deployment replicas
```

HPA desired replicas = **max** across all configured metrics (RPS, CPU, memory).

| Signal | Target (base) | Role |
|--------|---------------|------|
| RPS (External) | per-service `targetRequestsPerSecond` | Primary capacity under traffic |
| CPU | 70% utilization | Safety when load is compute-bound |
| Memory | 90% utilization | Safety valve only (near request / OOM-adjacent) |

## Services (base `values.yaml`)

| Service | min | max | RPS/pod target | Placement |
|---------|----:|----:|---------------:|-----------|
| `frontend-proxy` | 1 | 3 | 40 | Critical MNG |
| `frontend` | 1 | 6 | 15 | spot-tolerant |
| `product-catalog` | 1 | 6 | 30 | spot-tolerant |
| `cart` | 1 | 6 | 20 | spot-tolerant |
| `currency` | 1 | 6 | 50 | spot-tolerant |
| `checkout` | 1 | 6 | 5 | spot-tolerant |
| `recommendation` | 1 | 6 | 15 | spot-tolerant |

Targets are **starting points**, not SLOs. Raise if flapping; lower if latency climbs before CPU.

**Not request-scaled:** `load-generator`, Kafka consumers (`accounting`, `fraud-detection`), stateful data, `llm` (use concurrency/lag later).

The table shows the base/development floor. `values-prod.yaml` raises every
money-flow HPA above to `minReplicas: 2` for Directive #3 maintenance safety;
the maximum and metric targets remain unchanged.

## Metric name and labels

| Item | Value |
|------|--------|
| External metric name | `http_requests_per_second` (override per service: `autoscaling.customMetricName`) |
| Selector label | `service_name` = OTel `service.name` (default = component name; override: `autoscaling.serviceName`) |
| HPA target type | `AverageValue` (total service RPS ÷ current replicas) |

Adapter rules (in `values.yaml` → `prometheus-adapter.rules.external`) map, in order of discovery:

1. `rpc_server_duration_milliseconds_count` (gRPC backends)
2. `http_server_duration_milliseconds_count` / `http_server_request_duration_seconds_count` (HTTP)
3. `traces_span_metrics_calls_total` (spanmetrics fallback)

Each rule emits `sum(rate(...[1m])) by (service_name)`.

## Metric inventory (before tuning)

```bash
# Port-forward Prometheus
kubectl -n <ns> port-forward svc/prometheus 9090:9090

# In Prom UI or curl — list series and labels
# {__name__=~"rpc_server_duration_milliseconds_count|http_server_duration_milliseconds_count|traces_span_metrics_calls_total"}
```

Confirm:

* `service_name` matches component names (`cart`, `product-catalog`, …).
* Edge Envoy (`frontend-proxy`) has a usable series; if not, set `components.frontend-proxy.autoscaling.serviceName` or drop RPS for that service until metrics exist.

## Verification

```bash
# Adapter + custom metrics API
kubectl -n <ns> get deploy,pods -l app.kubernetes.io/name=prometheus-adapter
kubectl get apiservice | grep custom.metrics
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1" | head

# Metric value (label selector depends on adapter discovery)
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/<ns>/http_requests_per_second" | head

# HPA
kubectl -n <ns> get hpa
kubectl -n <ns> describe hpa frontend cart product-catalog currency checkout recommendation frontend-proxy
```

Expect External + Resource targets populated after traffic (not stuck `<unknown>` forever). Under Locust ramp, P0 services should scale when RPS/pod exceeds target even if CPU stays below 70% (especially `currency`).

## Tuning

Edit `components.<name>.autoscaling.targetRequestsPerSecond` in `values.yaml` (or overlay), sync chart.

Rough baseline:

```text
target ≈ (comfortable_total_RPS_at_good_latency) / current_replicas
```

Use Grafana APM / spanmetrics rate panels for total RPS.

## Failure modes

| Symptom | Cause | Action |
|---------|--------|--------|
| External TARGET `<unknown>` | Adapter down, wrong series/labels, no traffic yet | Check adapter logs; inventory Prom series; confirm `service_name` |
| Only CPU scales | RPS metric zero/missing | Fix adapter rules or instrumentation; CPU/mem still work |
| Flapping replicas | Target too low / noisy rate | Raise RPS target; rely on scaleDown stabilization (60s) |
| `frontend-proxy` Pending | Critical MNG full | Free Critical capacity or reviewed MNG size — do **not** raise chart `maxReplicas` without capacity review |
| Adapter Pending | Critical placement | Same as metrics-server; Critical floor capacity |

## Disable request metrics

```yaml
# values overlay
prometheus-adapter:
  enabled: false
```

Optionally remove `targetRequestsPerSecond` from components. CPU/memory HPA continues if Metrics Server is healthy.

## Related

* `docs/DEPLOYMENT.md` — install inventory and smoke checks
* `docs/operations/workload-placement.md` — node contracts under scale-out
* Chart: `templates/_objects.tpl` (`techx-corp.hpa`), `values.yaml` (`prometheus-adapter`, `components.*.autoscaling`)
