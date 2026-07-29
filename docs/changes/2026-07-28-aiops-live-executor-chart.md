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
- RBAC is namespace-scoped and limited to `Deployment/product-catalog`.
- NetworkPolicy allows ingress only from `aiops-runtime`.
- SQLite WAL state is stored on a dedicated PVC.
- `AIOPS_LIVE_EXECUTOR_ALLOW_LIVE_APPLY` defaults to `"false"`.

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

