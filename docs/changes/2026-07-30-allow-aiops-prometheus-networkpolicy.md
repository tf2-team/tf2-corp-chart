# Change: Allow AIOps Runtime Ingress to Prometheus in NetworkPolicy

## Summary

Add an explicit ingress rule to the `prometheus` `NetworkPolicy` template in `techx-corp-chart/templates/networkpolicy.yaml` allowing `aiops-runtime` pods to connect to Prometheus on TCP port `9090` when `.Values.aiops.enabled` is true.

## Context

During observability validation of the AI engine runtime (`aiops-runtime`), in-pod queries to `http://prometheus:9090/api/v1/query` timed out with `HTTP 504 Gateway Timeout`. Linkerd sidecar logs confirmed outbound connect failures to Prometheus port `9090`. Inspection of `kubectl get netpol prometheus -n techx-corp-prod` revealed that `aiops-runtime` was missing from the allowed ingress callers list for Prometheus.

## Before

`templates/networkpolicy.yaml` restricted Prometheus ingress (port `9090`) to `grafana`, `jaeger`, `prometheus-adapter`, `otel-collector`, and ALB CIDRs. `aiops-runtime` had outbound egress permissions to Prometheus, but Prometheus denied ingress from `aiops-runtime`.

## After

When `.Values.aiops.enabled` is true, the `prometheus` NetworkPolicy ingress rules now explicitly allow incoming traffic from `app.kubernetes.io/name: aiops-runtime` on TCP port `9090`.

## Technical Design Decisions

* **Least-Privilege Scoping:** Restricted ingress specifically to port `9090` from pods labeled `app.kubernetes.io/name: aiops-runtime`, guarded by the `aiops.enabled` flag.
* **GitOps Alignment:** Applied to `techx-corp-chart` templates to ensure Argo CD auto-reconciles the desired state without manual `kubectl` mutations.

## Implementation Details

1. Added the `aiops-runtime` ingress block to `prometheus` NetworkPolicy in `techx-corp-chart/templates/networkpolicy.yaml`.
2. Updated the change trail comment in `techx-corp-chart/templates/networkpolicy.yaml`.
3. Created this change record in `techx-corp-chart/docs/changes/2026-07-30-allow-aiops-prometheus-networkpolicy.md`.

## Files Changed

* `techx-corp-chart/templates/networkpolicy.yaml` — Added `aiops-runtime` ingress rule to `prometheus` NetworkPolicy on port 9090.
* `techx-corp-chart/docs/changes/2026-07-30-allow-aiops-prometheus-networkpolicy.md` — This change document.

## Dependencies and Cross-Repository Impact

None.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | `aiops-runtime` can successfully query Prometheus metrics for anomaly detection and RCA. |
| **Infrastructure** | Updates `prometheus` NetworkPolicy ingress rule in Kubernetes. |
| **Deployment** | Reconciled via Argo CD auto-sync. |
| **Security** | Minimal, least-privilege opening of port 9090 to internal AIOps runtime pod. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm Template Render | `helm template test-rel techx-corp-chart -f techx-corp-chart/values-aiops.yaml --set networkPolicy.enabled=true -s templates/networkpolicy.yaml` | ✅ Pass |

## Migration or Deployment Notes

Argo CD will automatically sync the updated `NetworkPolicy` to `techx-corp-prod`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| NetworkPolicy sync failure | Low | Low | Revert commit in `techx-corp-chart`. |

<!-- Change trail: @hungxqt - 2026-07-30 - Recorded NetworkPolicy update to allow aiops-runtime to query Prometheus. -->
