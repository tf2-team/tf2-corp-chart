# Báo cáo triển khai và kiểm thử Self-heal Executor

> Historical guarded-image result only. The pinned digest in this report
> predates the executor contract, HPA-safe scaling, approval, idempotency, and
> readiness fixes on `feat/aio/excuter`. It must not be used as acceptance
> evidence for a live rollout. Secure delivery must publish a new immutable
> digest and the guarded/live dev test must be repeated before promotion.

Ngày: 2026-07-29

## Tóm tắt

CDO đã triển khai `aiops-live-executor` lên namespace `techx-corp-prod` qua chart/GitOps và đã kiểm thử smoke test trực tiếp trên service.

Kết quả hiện tại:

- ArgoCD app `techx-corp`: `Synced / Healthy`
- ArgoCD app `techx-corp-secrets`: `Synced / Healthy`
- Deployment `aiops-live-executor`: `1/1`
- Pod `aiops-live-executor`: `2/2 Running`
- ExternalSecret `aiops-live-executor-token`: `SecretSynced / True`
- `AIOPS_LIVE_EXECUTOR_ALLOW_LIVE_APPLY=false`

Executor hiện chạy ở guarded mode. Các test execute/rollback là simulation/audit qua executor, không mutate Kubernetes thật.

## Artifact đã triển khai

Image executor đang chạy:

```text
493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/aiops@sha256:dc8d13fbde12dce83dfb0748b2ceda44e1154a3b559ec1091551d5c0b28af302
```

Resource chính trong `techx-corp-prod`:

- `Deployment/aiops-live-executor`
- `Service/aiops-live-executor`
- `ServiceAccount/aiops-live-executor`
- `Role/aiops-live-executor-deployment-writer`
- `RoleBinding/aiops-live-executor-deployment-writer`
- `PVC/aiops-live-executor-state`
- `NetworkPolicy/aiops-live-executor`
- `ExternalSecret/aiops-live-executor-token`
- `Secret/aiops-live-executor-token`

## Các cách kiểm thử có thể dùng

### 1. Kiểm tra GitOps và Kubernetes readiness

Mục tiêu: xác nhận ArgoCD đã sync chart mới, secret đã sync, pod chạy được.

Lệnh kiểm tra:

```bash
kubectl -n argocd get application techx-corp techx-corp-secrets -o wide
kubectl -n techx-corp-prod get deploy,pod,svc,externalsecret -l app.kubernetes.io/name=aiops-live-executor
kubectl -n techx-corp-prod get externalsecret aiops-live-executor-token
```

Tiêu chí pass:

- `techx-corp` là `Synced / Healthy`
- `techx-corp-secrets` là `Synced / Healthy`
- `Deployment/aiops-live-executor` là `1/1`
- Pod là `2/2 Running`
- ExternalSecret là `SecretSynced / True`

### 2. Health/readiness endpoint

Mục tiêu: xác nhận app FastAPI trong container trả lời được.

Lệnh kiểm tra:

```bash
kubectl -n techx-corp-prod port-forward svc/aiops-live-executor 18081:8080
curl -fsS http://127.0.0.1:18081/healthz
curl -fsS http://127.0.0.1:18081/readyz
```

Tiêu chí pass:

```json
{"status":"ok"}
{"status":"ready"}
```

### 3. Kiểm tra authentication

Mục tiêu: xác nhận endpoint action không cho request thiếu bearer token.

Lệnh kiểm tra:

```bash
curl -sS -o /tmp/aiops-unauth.json -w "%{http_code}" \
  -X POST http://127.0.0.1:18081/v1/actions/plan \
  -H "Content-Type: application/json" \
  -d "{}"
```

Tiêu chí pass:

```text
401
```

### 4. Kiểm tra action catalog

Mục tiêu: xác nhận executor expose đúng golden action P0.

Endpoint:

```text
GET /v1/actions/catalog
```

Header bắt buộc:

```text
Authorization: Bearer <token>
X-AIOPS-Account: aiops-runtime
X-Request-Id: <request-id>
```

Tiêu chí pass:

```json
["scale_product_catalog"]
```

### 5. Plan golden action

Mục tiêu: xác nhận executor tạo plan scale `product-catalog` từ 2 lên 3 replicas, có `plan_hash` và rollback token.

Endpoint:

```text
POST /v1/actions/plan
```

Tiêu chí pass:

- `allowed=true`
- `executed=false`
- `status=planned`
- `action_id=scale_product_catalog`
- `target=product-catalog`
- `before.replicas=2`
- `after.replicas=3`
- Có `plan_hash`
- Có `rollback.rollback_token`

### 6. Execute simulation

Mục tiêu: xác nhận executor nhận plan hợp lệ và ghi execution/audit. Vì `live_apply=false`, đây là simulation ở tầng executor, không patch Kubernetes.

Endpoint:

```text
POST /v1/actions/execute
```

Tiêu chí pass:

- `allowed=true`
- `executed=true`
- `status=running`
- Có `execution_id`
- `before.replicas=2`
- `after.replicas=3`

### 7. Status

Mục tiêu: xác nhận execution đã được persistent store ghi lại.

Endpoint:

```text
GET /v1/actions/{execution_id}
```

Tiêu chí pass:

- Trả về đúng `execution_id`
- `status=running`
- `target=product-catalog`

### 8. Rollback simulation

Mục tiêu: xác nhận rollback dùng snapshot của execution để restore replicas về 2 ở mức response/audit.

Endpoint:

```text
POST /v1/actions/{execution_id}/rollback
```

Tiêu chí pass:

- `allowed=true`
- `executed=true`
- `status=rolled_back`
- `after.replicas=2`

### 9. Guardrail protected target

Mục tiêu: xác nhận executor block target nằm trong protected list.

Ví dụ request dùng target `payment`.

Tiêu chí pass:

- `allowed=false`
- `executed=false`
- `status=blocked`
- `reasons` có `protected_target`

### 10. No live mutation check

Mục tiêu: xác nhận smoke test không làm thay đổi replicas thật của `product-catalog`.

Lệnh kiểm tra:

```bash
kubectl -n techx-corp-prod get deployment product-catalog \
  -o jsonpath='replicas={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
```

Tiêu chí pass:

```text
replicas=2 ready=2
```

## Kết quả smoke test đã chạy

CDO đã chạy smoke test trực tiếp qua port-forward `svc/aiops-live-executor`.

Kết quả:

```text
1_healthz
{"status":"ok"}

2_readyz
{"status":"ready"}

3_auth_required_status
http_status=401

4_catalog
["scale_product_catalog"]

5_plan_golden_action
allowed=true
executed=false
status=planned
target=product-catalog
before.replicas=2
after.replicas=3
plan_hash=sha256:8d242f6972a83542e130ee10d174bc5fa17049a7cfdeadbc026a5f81de4e6094
rollback_token=rbt:f5636c8b3472329f1f7df1559bd4374d75211a9025c45b87310c9cbdd9dea7a8

6_execute_simulation_no_live_apply
allowed=true
executed=true
status=running
execution_id=exec-fa68823577775dec
before.replicas=2
after.replicas=3

7_status
allowed=true
executed=true
status=running
execution_id=exec-fa68823577775dec
target=product-catalog

8_rollback_simulation_cleanup
allowed=true
executed=true
status=rolled_back
after.replicas=2

9_protected_target_block
allowed=false
executed=false
status=blocked
reasons=["protected_target","target_mismatch"]

10_product_catalog_replicas_after_smoke
replicas=2 ready=2
```

## Kết luận

Self-heal Executor đã được triển khai thành công và pass smoke test an toàn.

Executor hiện sẵn sàng để team AI tích hợp ở mức:

- gọi catalog;
- tạo plan;
- execute simulation/audit;
- query execution status;
- rollback simulation/audit;
- xác nhận guardrail block protected target.

Chưa bật live mutation. Khi muốn test live apply thật, cần có approval gate riêng và cập nhật implementation/script để cho phép `live_apply=true` theo policy đã được duyệt.
