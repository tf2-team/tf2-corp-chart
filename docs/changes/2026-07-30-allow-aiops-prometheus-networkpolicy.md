# Change: Allow AIOps Runtime Ingress to Prometheus in NetworkPolicy and Adjust Resource Limits

## Summary

Add an explicit ingress rule to the `prometheus` `NetworkPolicy` template in `techx-corp-chart/templates/networkpolicy.yaml` allowing `aiops-runtime` pods to connect to Prometheus on TCP port `9090` when `.Values.aiops.enabled` is true. Set `aiops-runtime` container resource requests to `200m` CPU / `512Mi` Memory and resource limits to `1000m` (1 CPU) / `1Gi` Memory in `values.yaml` and `values-aiops.yaml`.

## Context

During observability validation of the AI engine runtime (`aiops-runtime`), in-pod queries to `http://prometheus:9090/api/v1/query` timed out with `HTTP 504 Gateway Timeout`. Linkerd sidecar logs confirmed outbound connect failures to Prometheus port `9090`. Inspection of `kubectl get netpol prometheus -n techx-corp-prod` revealed that `aiops-runtime` was missing from the allowed ingress callers list for Prometheus. Furthermore, resource limits were doubled to accommodate multi-signal feature processing and RCA traversal without throttling.

## Before

* `templates/networkpolicy.yaml` restricted Prometheus ingress (port `9090`) to `grafana`, `jaeger`, `prometheus-adapter`, `otel-collector`, and ALB CIDRs. `aiops-runtime` had outbound egress permissions to Prometheus, but Prometheus denied ingress from `aiops-runtime`.
* `aiops-runtime` resource requests were `100m` CPU / `256Mi` Memory, and limits were `500m` CPU / `512Mi` Memory.

## After

* When `.Values.aiops.enabled` is true, the `prometheus` NetworkPolicy ingress rules now explicitly allow incoming traffic from `app.kubernetes.io/name: aiops-runtime` on TCP port `9090`.
* `aiops-runtime` resource requests are set to `200m` CPU / `512Mi` Memory, and resource limits are set to `1000m` (1 CPU) / `1Gi` Memory in `values.yaml` and `values-aiops.yaml`.

## Technical Design Decisions

* **Least-Privilege Scoping:** Restricted ingress specifically to port `9090` from pods labeled `app.kubernetes.io/name: aiops-runtime`, guarded by the `aiops.enabled` flag.
* **Doubled Resource Capacity:** Allocated 1 CPU core and 1GiB memory limit to balance processing capacity with cluster resource footprint.
* **GitOps Alignment:** Applied to `techx-corp-chart` templates and values overlays to ensure Argo CD auto-reconciles the desired state without manual `kubectl` mutations.

## Implementation Details

1. Added the `aiops-runtime` ingress block to `prometheus` NetworkPolicy in `techx-corp-chart/templates/networkpolicy.yaml`.
2. Updated `aiops.resources` in `techx-corp-chart/values.yaml` and `techx-corp-chart/values-aiops.yaml`.
3. Updated change trail comments across modified files.
4. Created this change record in `techx-corp-chart/docs/changes/2026-07-30-allow-aiops-prometheus-networkpolicy.md`.

## Files Changed

* `techx-corp-chart/templates/networkpolicy.yaml` — Added `aiops-runtime` ingress rule to `prometheus` NetworkPolicy on port 9090.
* `techx-corp-chart/values.yaml` — Adjusted `aiops.resources` requests to `200m`/`512Mi` and limits to `1000m`/`1Gi`.
* `techx-corp-chart/values-aiops.yaml` — Added `resources` block with `200m`/`512Mi` requests and `1000m`/`1Gi` limits to opt-in overlay.
* `techx-corp-chart/docs/changes/2026-07-30-allow-aiops-prometheus-networkpolicy.md` — This change document.

## Dependencies and Cross-Repository Impact

None.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | `aiops-runtime` can successfully query Prometheus metrics and run RCA loops with balanced resource headroom. |
| **Infrastructure** | Updates `prometheus` NetworkPolicy ingress rule and pod resource allocations in Kubernetes. |
| **Deployment** | Reconciled via Argo CD auto-sync. |
| **Security** | Minimal, least-privilege opening of port 9090 to internal AIOps runtime pod. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm Template Render | `helm template test-rel techx-corp-chart -f techx-corp-chart/values-aiops.yaml -s templates/aiops.yaml` | ✅ Pass |
| NetworkPolicy Render | `helm template test-rel techx-corp-chart -f techx-corp-chart/values-aiops.yaml --set networkPolicy.enabled=true -s templates/networkpolicy.yaml` | ✅ Pass |

## Migration or Deployment Notes

Argo CD will automatically sync the updated `NetworkPolicy` and `Deployment` resource limits to `techx-corp-prod`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Pod scheduling delay if node capacity is constrained | Low | Low | Nodes scale dynamically via Karpenter. |

<!-- Change trail: @hungxqt - 2026-07-30 - Recorded NetworkPolicy update and resource limits set to 1000m CPU / 1Gi Memory for aiops-runtime. -->
