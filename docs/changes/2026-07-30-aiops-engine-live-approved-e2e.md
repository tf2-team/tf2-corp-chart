# AIOps Engine live-approved self-heal overlay

Date: 2026-07-30

## Summary

- Promote the reviewed AIOps image digest for platform `origin/main` commit `d6f30bb`.
- Add `values-aiops-live-approved.yaml` to enable Engine-driven self-heal in `live-approved` mode.
- Add AIOps runtime overlays and digest pin to the production ArgoCD Application valueFiles.
- Align `aiops-runtime` and `aiops-live-executor` to the same immutable image digest.

## Image

- ECR repository: `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/aiops`
- Tag: `sha-d6f30bb`
- Digest: `sha256:f59cf4c6add9f940b7adfb81186f3009806d7a8f8b10c421cdc238450ecd817d`

## Validation

```bash
helm lint . \
  -f values.yaml \
  -f values-public-alb.yaml \
  -f values-prod.yaml \
  -f values-aiops.yaml \
  -f values-aiops-live-approved.yaml \
  -f values-aiops-live-executor.yaml \
  -f service-digest/values-aiops.yaml
```

Result: pass.

Rendered manifest checks confirmed:

- `Deployment/aiops-runtime` uses the promoted immutable digest.
- `Deployment/aiops-runtime` renders `AIOPS_POLICY_MODE=live-approved`.
- `Deployment/aiops-runtime` renders `AIOPS_SELF_HEAL_ENABLED=true`.
- `Deployment/aiops-runtime` references `aiops-live-executor-token` and `techx-corp-grafana-discord`.
- `Deployment/aiops-live-executor` uses the promoted immutable digest.
- `Deployment/aiops-live-executor` renders `AIOPS_LIVE_EXECUTOR_ALLOW_LIVE_APPLY=true`.
- Executor RBAC remains limited to allowlisted Deployment/HPA resources:
  `product-catalog`, `frontend-proxy`, `frontend`, `checkout`, and `cart`.
