# PER-01 — Resource Right-sizing for Workloads

**Date:** 2026-07-22  
**Status:** Accepted  
**Priority:** P1  
**Pillar:** Performance Efficiency & Cost Optimization  
**Author / Signer:** Nguyễn Đức Chinh  
**Team:** CDO-03  

---

## Context

The TechX Corp microservices platform runs 30 workloads under continuous load testing (via Locust load generator). The initial configuration in `values.yaml` contained arbitrary resource requests and limits that did not reflect actual application behavior or requirements.

This led to major inefficiencies:
- **Over-provisioning (Waste):** Lightweight services (e.g., `shipping` in Rust, `quote` in PHP, `product-catalog` in Go) had request floors of 50m-100m CPU and 100Mi-256Mi memory, wasting compute capacity and preventing Karpenter from performing node consolidation.
- **Under-provisioning (OOM Risk):** AI workloads (`product-reviews`, `shopping-copilot`) had memory limits set at 2Gi, while their actual memory footprints under model loading were ~1.78GiB and ~1.72GiB respectively, risking OOMKills under peak traffic.
- **Probe Throttling:** Setting CPU limits too tightly on JVM (`ad`), Node.js (`payment`), or `metrics-server` caused liveness probe timeouts during cold start, leading to container restart loops.
- **ValidatingAdmissionPolicy Compliance:** Cluster security policy `runtime-hardening-pod-template.techx.io` (Mandate 5) requires all containers to explicitly define both CPU and Memory requests and limits.

To resolve these issues, we collected metrics under active load testing:
1. **P99 CPU & Memory metrics** from a **30-minute load test window under 50 active users**.
2. **Prometheus metrics & Grafana dashboard (`webstore-performance.json`)** to cross-verify container resource usage and allocation stats.

---

## Decision

We right-sized CPU and Memory resource configurations across all 30 microservices and infrastructure components in `values.yaml` based on empirical P99 metrics and Kubernetes Quality of Service (QoS) classification rules:

### Sizing Methodology
1. **Guaranteed QoS (Request = Limit):** Applied to critical transaction path services (`checkout`, `cart`, `payment`, `frontend-proxy`, `product-catalog`, `currency`, `quote`, `shipping`) and core platform infrastructure (`prometheus-server`, `opensearch`, `otel-collector`, `prometheus-adapter`, `metrics-server`). Setting `requests = limits` prevents noisy-neighbor CPU starvation and guarantees eviction protection.
2. **Burstable QoS (Request < Limit):** Applied to non-transactional, bursty, or AI/ML workloads (`frontend`, `product-reviews`, `shopping-copilot`, `recommendation`, `llm`, `ad`, `accounting`, `fraud-detection`, `email`, `flagd`, `jaeger`, `grafana`, `kube-state-metrics`, `image-provider`, `load-generator`, `load-generator-worker`, `flagd-ui`). CPU limits are set with generous headroom (3x–10x over requests) to satisfy `ValidatingAdmissionPolicy` while preventing cold-start probe timeouts.
3. **Memory Requests & Limits:** Memory requests are set with a 15–30% safety buffer over P99 memory usage to prevent scheduling on memory-constrained nodes. Heavy AI services (`product-reviews`, `shopping-copilot`) have memory requests set to 1920Mi and limits to 2560Mi to accommodate model binaries safely. `flagd` is configured with `limits.memory: 128Mi` (requests `64Mi`) to align with `GOMEMLIMIT: 100MiB` and prevent OOMKills under heavy gRPC feature-flag query volume.

---

## Technical Details

The following resource configurations were applied to `values.yaml`:

### 1. Application Microservices (Purchase Path & Business Logic)
- **`checkout` (Go):** `requests: 10m / 32Mi`, `limits: 10m / 32Mi` (P99: 5.1m CPU, 27.47Mi Memory - Guaranteed QoS).
- **`cart` (.NET):** `requests: 15m / 96Mi`, `limits: 15m / 96Mi` (P99: 8.3m CPU, 75.96Mi Memory - Guaranteed QoS).
- **`payment` (Node.js):** `requests: 10m / 160Mi`, `limits: 100m / 160Mi` (P99: 5.3m CPU, 122.78Mi Memory - limits.cpu raised to 100m for Node.js V8 boot probe safety).
- **`frontend-proxy` (Envoy):** `requests: 30m / 48Mi`, `limits: 30m / 48Mi` (P99: 17.5m CPU, 30.20Mi Memory - Guaranteed QoS).
- **`product-catalog` (Go):** `requests: 20m / 32Mi`, `limits: 20m / 32Mi` (P99: 9.2m CPU, 19.51Mi Memory - Guaranteed QoS).
- **`currency` (C++):** `requests: 10m / 16Mi`, `limits: 10m / 16Mi` (P99: 2.8m CPU, 12.98Mi Memory - Guaranteed QoS).
- **`quote` (PHP):** `requests: 10m / 32Mi`, `limits: 10m / 32Mi` (P99: 1.0m CPU, 25.57Mi Memory - Guaranteed QoS).
- **`shipping` (Rust):** `requests: 10m / 16Mi`, `limits: 10m / 16Mi` (P99: 0.8m CPU, 6.94Mi Memory - Guaranteed QoS).
- **`flagd` (OpenFeature daemon):** `requests: 10m / 64Mi`, `limits: 100m / 128Mi` (P99: 9.2m CPU, 46.92Mi Memory - Memory limit set to 128Mi for GOMEMLIMIT 100MiB safety and limits.cpu raised to 100m for gRPC probe safety under load).
- **`frontend` (Next.js SSR):** `requests: 64m / 160Mi`, `limits: 200m / 256Mi` (P99: 37.2m CPU, 117.21Mi Memory).
- **`product-reviews` (Python AI):** `requests: 32m / 1920Mi`, `limits: 200m / 2560Mi` (P99: 12.3m CPU, 1824.49Mi Memory - Model loading protection).
- **`shopping-copilot` (Python AI):** `requests: 20m / 1920Mi`, `limits: 200m / 2560Mi` (P99: 0.7m CPU, 1759.50Mi Memory - Model loading protection).
- **`ad` (JVM):** `requests: 10m / 288Mi`, `limits: 200m / 384Mi` (P99: 2.8m CPU, 260.47Mi Memory - limits.cpu raised to 200m for JVM/OTel probe safety).
- **`accounting` (C#):** `requests: 20m / 256Mi`, `limits: 100m / 384Mi` (P99: 14.3m CPU, 218.08Mi Memory).
- **`fraud-detection` (Kotlin/JVM):** `requests: 10m / 352Mi`, `limits: 100m / 448Mi` (P99: 5.2m CPU, 309.26Mi Memory).
- **`recommendation` (Python):** `requests: 20m / 80Mi`, `limits: 100m / 144Mi` (P99: 9.2m CPU, 60.39Mi Memory).
- **`email` (Ruby):** `requests: 10m / 80Mi`, `limits: 50m / 128Mi` (P99: 3.7m CPU, 65.02Mi Memory).
- **`llm` (Python):** `requests: 10m / 80Mi`, `limits: 100m / 128Mi` (P99: 7.6m CPU, 74.68Mi Memory).
- **`image-provider` (Nginx):** `requests: 5m / 16Mi`, `limits: 20m / 32Mi` (P99: 0.5m CPU, 11.13Mi Memory).
- **`flagd-ui` (Elixir sidecar):** `requests: 5m / 144Mi`, `limits: 20m / 192Mi` (P99: 0.3m CPU, 139.55Mi Memory).
- **`load-generator` (Locust master):** `requests: 20m / 96Mi`, `limits: 100m / 160Mi` (P99: 16.6m CPU, 80.27Mi Memory).
- **`load-generator-worker` (Locust worker):** `requests: 35m / 112Mi`, `limits: 500m / 192Mi`.

### 2. Infrastructure & Observability Platform Components
- **`prometheus-server` (Go):** `requests: 200m / 1792Mi`, `limits: 200m / 1792Mi` (P99: 193.8m CPU, 1668.75Mi Memory - Guaranteed QoS).
- **`opensearch` (JVM):** `requests: 100m / 960Mi`, `limits: 100m / 960Mi` (P99: 87.9m CPU, 917.30Mi Memory - Guaranteed QoS).
- **`otel-collector` (DaemonSet):** `requests: 20m / 128Mi`, `limits: 20m / 128Mi` (P99: 13.3m CPU, 117.86Mi Memory - Guaranteed QoS).
- **`metrics-server` (Go):** `requests: 10m / 32Mi`, `limits: 50m / 32Mi` (P99: 5.3m CPU, 27.29Mi Memory - limits.cpu raised to 50m for /livez probe safety).
- **`prometheus-adapter` (Go):** `requests: 10m / 48Mi`, `limits: 10m / 48Mi` (P99: 5.4m CPU, 38.18Mi Memory - Guaranteed QoS).
- **`jaeger` (Go):** `requests: 20m / 384Mi`, `limits: 100m / 1Gi` (P99: 7.9m CPU, 307.78Mi Memory).
- **`grafana` (Go/JS):** `requests: 20m / 448Mi`, `limits: 100m / 768Mi` (P99: 15.3m CPU, 381.94Mi Memory).
- **`kube-state-metrics` (Go):** `requests: 5m / 32Mi`, `limits: 50m / 64Mi` (P99: 2.4m CPU, 29.01Mi Memory).

---

## Consequences

### Positive
- **Zero CrashLoopBackOff & 100% Pod Health:** Eliminated all cold-start probe failures (`ad`, `payment`, `metrics-server`, `flagd`) while preventing OOMKills on heavy AI/analytics workloads (`product-reviews`, `shopping-copilot`, `opensearch`, `prometheus-server`, `flagd`).
- **Cost Optimization & Bin-Packing:** Reduced CPU requests on idle workloads (from 100m to 5m-20m), enabling Karpenter to pack pods efficiently and scale down unnecessary EC2 nodes under low traffic.
- **Strict Policy Compliance:** Fully satisfies `ValidatingAdmissionPolicy` (`runtime-hardening-pod-template.techx.io`), ensuring seamless CI/CD merging into `main`.
- **Noisy Neighbor Protection:** Critical purchase path services are isolated with Guaranteed QoS (`request = limit`).

### Negative / Trade-offs
- **Cold-Start Burst Overhead:** Heavy JVM (`ad`), Node.js (`payment`), and Go (`flagd`) pods require slightly higher CPU limits (`100m-200m`) during startup, but their steady-state CPU footprint remains minimal (`10m`).