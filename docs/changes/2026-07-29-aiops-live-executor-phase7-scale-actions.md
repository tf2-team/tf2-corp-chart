# AIOps live executor Phase 7 scale actions

Ngay cap nhat: 2026-07-29

## Thay doi

- Mo rong RBAC executor tu `Deployment/product-catalog` sang allowlist:
  - `product-catalog`
  - `frontend-proxy`
  - `frontend`
  - `checkout`
  - `cart`
- Doi values tu `rbac.targetDeployment` sang `rbac.targetDeployments`.
- Them env cooldown va action budget:
  - `AIOPS_LIVE_EXECUTOR_COOLDOWN_SECONDS`
  - `AIOPS_LIVE_EXECUTOR_ACTION_BUDGET_WINDOW_SECONDS`
  - `AIOPS_LIVE_EXECUTOR_ACTION_BUDGET_MAX_EXECUTIONS`
- Them overlay `values-aiops-live-executor-live-test.yaml` de bat live apply co chu dich trong namespace dev/demo approved.

## Guardrail

- Default `values.yaml` van `aiopsLiveExecutor.enabled=false`.
- Overlay `values-aiops-live-executor.yaml` deploy executor nhung van giu `AIOPS_LIVE_EXECUTOR_ALLOW_LIVE_APPLY=false`.
- Chi overlay live-test moi set `AIOPS_LIVE_EXECUTOR_ALLOW_LIVE_APPLY=true`.
- RBAC van chi cap quyen `get`, `patch`, `update` cho `apps/deployments` dung resourceNames allowlisted.

## Validation

```text
helm lint . -f values-aiops-live-executor.yaml: pass
helm lint . -f values-aiops-live-executor-live-test.yaml: pass
helm template default overlay: pass
helm template live-test overlay: pass
```
