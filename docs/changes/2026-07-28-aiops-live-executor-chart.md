# 2026-07-28 - AIOps Live Executor Chart

## Summary

Added an opt-in Helm deployment path for the self-heal live executor.

The executor is disabled by default and must only be enabled in a dev/demo namespace approved for the golden `scale_product_catalog` action.

## Added

- `aiopsLiveExecutor` values block in `values.yaml`
- `values-aiops-live-executor.yaml` opt-in overlay
- `templates/aiops-live-executor.yaml`
- `values.schema.json` validation for `aiopsLiveExecutor`

## Safety Boundary

- AIOps runtime remains read-only.
- Executor gets its own ServiceAccount.
- RBAC is namespace-scoped and limited to `Deployment/product-catalog` and
  `HorizontalPodAutoscaler/product-catalog`.
- NetworkPolicy allows ingress only from `aiops-runtime`.
- Live mode allows executor egress only to the Kubernetes API, and runtime
  egress to the executor only when self-heal is enabled.
- SQLite WAL state is stored on a dedicated PVC.
- `AIOPS_LIVE_EXECUTOR_ALLOW_LIVE_APPLY` defaults to `"false"`.
- Live mode requires the token and approval ID from the configured Secret.
- Runtime self-heal configuration fails Helm rendering unless policy mode,
  executor enablement, and live apply are enabled together.
- The executor temporarily owns `HPA/product-catalog.spec.minReplicas` and
  restores the chart floor after successful verification or rollback. The
  live-activation GitOps change must prevent Argo self-heal from reconciling
  that one field during the bounded verification window; guarded mode does not
  add a permanent ignore rule.

## Validation

```bash
helm lint . -f values-aiops-live-executor.yaml
```

Result:

```text
1 chart(s) linted, 0 chart(s) failed
```

```bash
helm template techx-corp . \
  -n techx-corp-prod \
  -f values-aiops-live-executor.yaml \
  --show-only templates/aiops-live-executor.yaml
```

Result: rendered successfully.

```bash
helm template techx-corp . \
  -n techx-corp-prod \
  -f values-aiops-live-executor.yaml
```

Result: rendered successfully, 33796 lines.

