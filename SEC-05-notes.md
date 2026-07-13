# SEC-05: NetworkPolicy — East-West Traffic Restriction Notes

This document summarises the NetworkPolicy implementation added to the TechX Corp Platform
Helm Chart as part of the SEC-05 security track, including the traffic matrix, design
decisions, and known exceptions.

---

## What was implemented

A set of `networking.k8s.io/v1` NetworkPolicy objects rendered by `templates/networkpolicy.yaml`,
controlled by the `networkPolicy.enabled` flag in `values.yaml` (default `false`).

**Total policies: 29**

| # | Policy name | Type |
|---|-------------|------|
| 1 | `default-deny-all-ingress` | Namespace-wide default deny |
| 2 | `allow-dns-egress` | Namespace-wide DNS allow |
| 3 | `allow-to-otel-collector` | Infra — OTel ingress |
| 4 | `frontend-proxy` | App |
| 5 | `frontend` | App |
| 6 | `checkout` | App |
| 7 | `cart` | App |
| 8 | `payment` | App |
| 9 | `shipping` | App |
| 10 | `quote` | App |
| 11 | `currency` | App |
| 12 | `email` | App |
| 13 | `ad` | App |
| 14 | `recommendation` | App |
| 15 | `product-catalog` | App |
| 16 | `product-reviews` | App |
| 17 | `accounting` | App |
| 18 | `fraud-detection` | App |
| 19 | `kafka` | Data plane |
| 20 | `valkey-cart` | Data plane |
| 21 | `postgresql` | Data plane |
| 22 | `llm` | App |
| 23 | `image-provider` | App |
| 24 | `load-generator` | App |
| 25 | `flagd` | Control plane |
| 26 | `opensearch` | Data plane |
| 27 | `prometheus` | Observability |
| 28 | `jaeger` | Observability |
| 29 | `grafana` | Observability |

---

## Traffic matrix (required flows)

### Application tier

| Source | Destination | Port | Justification |
|--------|-------------|------|---------------|
| frontend-proxy | frontend | 8080 | BFF proxy |
| frontend-proxy | grafana | 80 | Observability UI |
| frontend-proxy | jaeger | 16686 | Tracing UI |
| frontend-proxy | image-provider | 8081 | Product images |
| frontend-proxy | load-generator | 8089 | Locust UI |
| frontend-proxy | flagd | 8013 / 4000 | Feature flags + flagd-ui |
| frontend | ad, cart, checkout, currency, product-catalog | 8080 | BFF calls |
| frontend | product-reviews | 3551 | gRPC reviews |
| frontend | recommendation, shipping | 8080 | BFF calls |
| frontend | flagd | 8013 / 8016 | Feature flags |
| checkout | cart, currency, email, payment, product-catalog, shipping | 8080 | Order orchestration |
| checkout | kafka | 9092 | Order events |
| checkout | flagd | 8013 / 8016 | Feature flags |
| cart | valkey-cart | 6379 | Session state |
| cart | flagd | 8013 / 8016 | Feature flags |
| recommendation | product-catalog | 8080 | Catalog lookup |
| product-catalog | postgresql | 5432 | Product data |
| product-reviews | product-catalog | 8080 | Catalog lookup |
| product-reviews | llm | 8000 | AI review generation |
| product-reviews | postgresql | 5432 | Review data |
| shipping | quote | 8080 | Shipping quote |
| accounting | kafka | 9092 | Order event consumer |
| accounting | postgresql | 5432 | Accounting records |
| fraud-detection | kafka | 9092 | Order event consumer |

### Telemetry (all app pods)

| Source | Destination | Port | Justification |
|--------|-------------|------|---------------|
| all pods | otel-collector | 4317 / 4318 | OTLP traces, metrics, logs |
| otel-collector | kafka | 9092 | kafkametrics scrape |
| otel-collector | valkey-cart | 6379 | Redis metrics scrape |
| otel-collector | postgresql | 5432 | PostgreSQL metrics scrape |
| otel-collector | jaeger | 4317 | Trace export |
| otel-collector | prometheus | 9090 | Metric export (OTLP) |
| otel-collector | opensearch | 9200 | Log export |

### Observability stack

| Source | Destination | Port | Justification |
|--------|-------------|------|---------------|
| jaeger | prometheus | 9090 | Metrics backend for SPM |
| grafana | prometheus | 9090 | Metrics datasource |
| grafana | jaeger | 16686 | Tracing datasource |
| grafana | opensearch | 9200 | Log datasource |

---

## Design decisions

### 1. Default deny ingress only (not egress)

Egress is **not** default-denied at this phase. Reasons:

- Prometheus requires egress to every pod it scrapes via Kubernetes SD; enumerating all
  targets explicitly is brittle and would break when new services are added.
- `initContainers` using `busybox nc` for wait-for-* checks need egress to data-plane pods.
- Ingress-only default-deny already covers the primary threat: a compromised pod being
  reachable from pods that have no business talking to it.

Egress default-deny is a follow-up hardening step.

### 2. Pod selector key: `opentelemetry.io/name`

All first-party pods carry `opentelemetry.io/name: <component-name>` set by `_helpers.tpl`
`selectorLabels`. This label is already used for OTel service discovery, so no new labels
were needed.

Subchart pods (prometheus, grafana, jaeger) are matched by their upstream
`app.kubernetes.io/name` labels. The OTel Collector DaemonSet is matched by
`app.kubernetes.io/component: otel-collector`.

### 3. Hyphenated component names use `index` syntax

Helm template dot-notation cannot reference keys with hyphens. Components with hyphenated
names (`frontend-proxy`, `product-catalog`, `product-reviews`, `fraud-detection`,
`valkey-cart`, `image-provider`, `load-generator`) use:

```
{{- if (index .Values.components "frontend-proxy").enabled }}
```

### 4. Feature flag `networkPolicy.enabled: false`

Policies are opt-in so existing clusters are not affected until the operator consciously
enables them after a CNI audit.

---

## CNI prerequisite

NetworkPolicy objects are **silently ignored** unless the cluster CNI enforces them.

| CNI | Enforcement |
|-----|-------------|
| AWS VPC CNI ≥ 1.14 with `ENABLE_NETWORK_POLICY=true` | ✅ |
| Calico | ✅ |
| Cilium | ✅ |
| Flannel (vanilla) | ❌ |

Verify on EKS:

```bash
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[*].env}' | grep NETWORK_POLICY
```

---

## Known gaps / follow-up items

| Gap | Notes |
|-----|-------|
| Egress default-deny | Not applied in this phase — see Design decision #1 |
| Prometheus scrape egress | Uses `podSelector: {}` (broad); can be tightened to explicit label selectors later |
| External egress for `llm` | If `llm` calls external APIs (e.g. OpenAI), an `ipBlock` egress rule is needed after auditing the actual CIDRs |
| CI policy linting | No automated check that a new service call is reflected in the NetworkPolicy template — add `np-lint` or equivalent to CI |

---

## Files changed

| File | Change |
|------|--------|
| `templates/networkpolicy.yaml` | New — 29 NetworkPolicy objects |
| `values.yaml` | Added `networkPolicy.enabled: false` |
| `docs/operations/network-policy.md` | New — traffic matrix, rollout guide, debug steps |
| `docs/adr/SEC-05-network-policy.md` | New — decision record |
| `SEC-05-notes.md` | This file |
