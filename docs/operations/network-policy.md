# NetworkPolicy — east-west traffic restriction (SEC-05)

Helm value: `networkPolicy.enabled` (default `false`)

---

## Why

Without NetworkPolicy every pod in the namespace can reach every other pod on any port.
If one pod is compromised an attacker gets free lateral movement across the entire workload.
Enabling these policies limits that blast radius: a compromised `recommendation` pod cannot
reach `kafka`, `postgresql`, or `payment` even if it tries.

---

## CNI prerequisite

NetworkPolicy objects are inert unless the cluster's CNI plugin enforces them.

| CNI | Policy support |
|-----|----------------|
| AWS VPC CNI ≥ 1.14 + `ENABLE_NETWORK_POLICY=true` on aws-node DaemonSet | ✅ |
| Calico | ✅ |
| Cilium | ✅ |
| Flannel (vanilla) | ❌ — policies are silently ignored |

Verify before enabling:

```bash
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[*].env}' | grep NETWORK_POLICY
```

Expected: `"name":"ENABLE_NETWORK_POLICY","value":"true"`

---

## Traffic matrix

The table below is the authoritative source of truth; the Helm template encodes it exactly.

### Legend

| Symbol | Meaning |
|--------|---------|
| → | egress allowed from row to column |
| ← | ingress allowed into row from column |
| ✗  | no policy rule; blocked by default-deny |

### Application tier

| Service | Receives from | Calls |
|---------|---------------|-------|
| **frontend-proxy** | ALB / external | frontend, grafana, jaeger, image-provider, load-generator, flagd |
| **frontend** | frontend-proxy, load-generator | ad, cart, checkout, currency, product-catalog, product-reviews, recommendation, shipping, flagd |
| **checkout** | frontend | cart, currency, email, payment, product-catalog, shipping, kafka |
| **cart** | frontend, checkout | valkey-cart, flagd |
| **payment** | checkout | flagd |
| **shipping** | frontend, checkout | quote |
| **quote** | shipping | — |
| **currency** | frontend, checkout | — |
| **email** | checkout | flagd |
| **ad** | frontend | flagd |
| **recommendation** | frontend | product-catalog, flagd |
| **product-catalog** | frontend, checkout, recommendation, product-reviews | postgresql, flagd |
| **product-reviews** | frontend | product-catalog, llm, postgresql, flagd |
| **accounting** | — (Kafka consumer) | kafka, postgresql |
| **fraud-detection** | — (Kafka consumer) | kafka, flagd |
| **llm** | product-reviews | flagd |
| **image-provider** | frontend-proxy | — |
| **load-generator** | frontend-proxy (UI) | frontend-proxy |
| **flagd** | all feature-flag clients | otel-collector |

### Data / infra tier

| Service | Receives from | Notes |
|---------|---------------|-------|
| **kafka** | checkout, accounting, fraud-detection, otel-collector | otel-collector scrapes kafkametrics on :9092 |
| **valkey-cart** | cart, otel-collector | otel-collector scrapes redis metrics |
| **postgresql** | product-catalog, product-reviews, accounting, otel-collector | otel-collector scrapes postgresql metrics |
| **opensearch** | otel-collector (log exporter), grafana | |

### Observability tier

| Service | Receives from | Calls |
|---------|---------------|-------|
| **otel-collector** | all pods (:4317/:4318), kafka (:9092 kafkametrics), redis/pg scrape | jaeger, prometheus, opensearch |
| **prometheus** | otel-collector, grafana, jaeger, prometheus-adapter | all pods (scrape), kube-system nodes |
| **jaeger** | otel-collector (:4317), frontend-proxy, grafana | prometheus |
| **grafana** | frontend-proxy | prometheus, jaeger, opensearch |

---

## Enabling

```bash
# Step 1: dry-run to see what would be created
helm upgrade techx-corp . \
  --namespace techx-corp \
  --set networkPolicy.enabled=true \
  --dry-run | grep "kind: NetworkPolicy" | wc -l
# Expected: 29

# Step 2: apply in dev
helm upgrade techx-corp . \
  --namespace techx-corp \
  --set networkPolicy.enabled=true
```

Or in your `values-dev.yaml` / `values-prod.yaml`:

```yaml
networkPolicy:
  enabled: true
```

---

## Roll-out phases

### Phase 1 — audit (no enforcement yet)

Deploy with `networkPolicy.enabled: false`.
Use a CNI audit tool to preview what traffic would be blocked:

```bash
# Cilium: export policies and simulate
# Calico: use calicoctl policy-advisor
# Generic: netassert / np-viewer
kubectl get netpol -n techx-corp   # should be empty at this stage
```

Check existing connections with:

```bash
# Confirm which service talks to which via OTel traces in Jaeger
# or via Prometheus span-metrics service graph
```

### Phase 2 — enforce in dev

```bash
helm upgrade techx-corp . -n techx-corp -f values-dev.yaml \
  --set networkPolicy.enabled=true
```

Soak for at least 24 hours. Watch for:

```bash
# Pod logs showing connection refused / timeout
kubectl logs -n techx-corp -l app.kubernetes.io/part-of=techx-corp \
  --since=1h | grep -i "connection refused\|dial tcp\|i/o timeout"

# OTel traces: look for broken spans in Jaeger
# Prometheus: spike in http_server_errors or grpc_server_handled{grpc_code="Unavailable"}
```

### Phase 3 — promote to prod

After a clean dev soak, update `values-prod.yaml`:

```yaml
networkPolicy:
  enabled: true
```

---

## Debugging a blocked connection

```bash
# 1. Identify the pods involved
kubectl get pods -n techx-corp -l opentelemetry.io/name=checkout

# 2. Check which NetworkPolicy applies to the source pod
kubectl describe netpol checkout -n techx-corp

# 3. Confirm the destination pod's selector labels match the policy
kubectl get pod <pod-name> -n techx-corp --show-labels

# 4. For AWS VPC CNI, check the node-level policy agent logs
kubectl logs -n kube-system -l k8s-app=aws-node -c aws-network-policy-agent \
  --since=10m | grep -i "drop\|deny"

# 5. For Cilium
cilium monitor --type drop -n techx-corp
```

---

## Adding a new service

1. Add an egress rule in **each caller's** policy block.
2. Add an ingress rule in the **new service's** policy block.
3. Add the new service's policy block to `templates/networkpolicy.yaml`.
4. Update this document's traffic matrix table.

Example: adding a new `loyalty` service called by `checkout`:

```yaml
# In the checkout policy egress section:
- to:
    - podSelector:
        matchLabels:
          opentelemetry.io/name: loyalty
  ports:
    - protocol: TCP
      port: 8080

# New loyalty policy block:
{{- if .Values.components.loyalty.enabled }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: loyalty
spec:
  podSelector:
    matchLabels:
      opentelemetry.io/name: loyalty
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              opentelemetry.io/name: checkout
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: otel-collector
      ports:
        - protocol: TCP
          port: 4317
{{- end }}
```

---

## Known gaps / follow-up

| Item | Notes |
|------|-------|
| External egress (OpenAI API from `product-reviews`) | `llm` service acts as proxy; `product-reviews` only talks to in-cluster `llm`. If `llm` itself calls external endpoints, add an egress rule with `ipBlock` after auditing the actual CIDR. |
| `prometheus` scrape egress | Policy allows `podSelector: {}` (all pods in namespace) to keep Prometheus SD working without enumerating every scrape target. Tighten to explicit selectors if a stricter posture is required. |
| `initContainers` wait-for-* (busybox nc) | Init containers run before main containers; they need the same egress as the main container. The per-pod Egress policy covers them since NetworkPolicy applies at the pod level. |
| Karpenter node registration | Node → API server traffic is outside the namespace scope; NetworkPolicy does not affect it. |
