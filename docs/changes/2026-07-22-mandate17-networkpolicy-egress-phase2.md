# Mandate 17 — Phase 2: Egress enforcement + egress proxy

**Date:** 2026-07-22
**Author:** @cdo06
**Mandate:** DIRECTIVE #17 — Chịu được sự cố, khoanh được kẻ xâm nhập
**Trụ:** Security (blast-radius containment — egress isolation)
**Depends on:** Phase 1 (`2026-07-21-mandate17-networkpolicy-rbac-phase1.md`) — phải verify ổn trước.
**Risk:** Medium — egress proxy là điểm trung gian mới cho external HTTPS calls.

---

## Thay đổi

### 1. Bật egress enforcement (`values-prod.yaml`)

```diff
  networkPolicy:
    enabled: true
-   enforceEgress: false
+   enforceEgress: true

- egressProxy:
-   enabled: false
+ egressProxy:
+   enabled: true
```

### 2. Grafana proxy env vars (`values-prod.yaml`)

```yaml
grafana:
  env:
    HTTPS_PROXY: http://egress-proxy:10000
    https_proxy: http://egress-proxy:10000
    NO_PROXY: .svc,.svc.cluster.local,localhost,127.0.0.1,10.0.0.0/8
    no_proxy: .svc,.svc.cluster.local,localhost,127.0.0.1,10.0.0.0/8
```

Grafana gọi Discord (alert webhook) và Athena/S3 (CUR datasource) qua HTTPS.
Khi egress bị enforce, các call này phải đi qua egress proxy thay vì gọi thẳng.

---

## Kiến trúc egress proxy

Envoy proxy chạy như một Deployment riêng, chỉ cho phép CONNECT tunnel đến domain allowlist:

| Domain | Dùng bởi | Mục đích |
|---|---|---|
| `api.groq.com:443` | `product-reviews` | LLM API calls |
| `bedrock-runtime.us-east-1.amazonaws.com:443` | `shopping-copilot` | AWS Bedrock |
| `sts.us-east-1.amazonaws.com:443` | `checkout`, `shopping-copilot` | AWS STS (IRSA token) |
| `dynamodb.us-east-1.amazonaws.com:443` | `checkout` | DynamoDB outbox |
| `s3.us-east-1.amazonaws.com:443` | multiple | S3 model fetch |
| `discord.com:443` | `grafana` | Alert webhook |
| `athena/glue/sts/s3.ap-southeast-1.amazonaws.com:443` | `grafana` | CUR datasource |

**Callers được phép qua proxy:** `checkout`, `grafana`, `product-reviews`, `shopping-copilot`
**Tất cả pod khác:** không có egress rule đến egress-proxy → bị block hoàn toàn.

---

## Những gì được enforce sau Phase 2

Mỗi pod chỉ được gọi ra đúng danh sách:

| Service | Egress được phép |
|---|---|
| `frontend` | ad, cart, checkout, currency, product-catalog, product-reviews, shopping-copilot, recommendation, shipping, flagd, otel-collector |
| `checkout` | cart, currency, email, payment, product-catalog, shipping, kafka/MSK (VPC CIDR), egress-proxy, flagd, otel-collector |
| `product-reviews` | product-catalog, llm, postgresql/RDS (VPC CIDR), egress-proxy, flagd, otel-collector |
| `payment` | flagd, otel-collector (không cần external) |
| `accounting` | kafka/MSK (VPC CIDR), postgresql/RDS (VPC CIDR), otel-collector |
| `fraud-detection` | kafka/MSK (VPC CIDR), valkey/ElastiCache (VPC CIDR), flagd, otel-collector |
| `ad`, `email`, `currency`, `quote` | flagd, otel-collector only |

---

## Verify sau deploy

```powershell
# 1. Egress proxy pod đang chạy
kubectl -n techx-corp-prod get pods | Select-String "egress-proxy"
# → egress-proxy-<hash>   1/1   Running

# 2. NetworkPolicy egress-proxy tồn tại
kubectl -n techx-corp-prod get networkpolicy egress-proxy

# 3. Tất cả pod vẫn Running
kubectl -n techx-corp-prod get pods

# 4. Test storefront end-to-end
# - Storefront load: http://<alb>/
# - AI summary hiển thị (product-reviews → groq qua proxy)
# - Checkout thành công (checkout → MSK, DynamoDB qua proxy)
# - Grafana alert rules không bị lỗi HTTPS

# 5. Xem egress proxy log — verify domain đang đi qua
kubectl -n techx-corp-prod logs deploy/egress-proxy --tail=50
```

---

## Rollback

**Nếu egress proxy crash hoặc service không gọi được external:**
```powershell
# Option 1: Rollback về Phase 1 (ingress-only)
# Sửa values-prod.yaml: enforceEgress: false, egressProxy.enabled: false
# helm upgrade ...

# Option 2: Helm rollback toàn bộ
helm -n techx-corp-prod rollback techx-corp
```

**Lưu ý:** `checkout` và `product-reviews` là critical path — nếu 2 service này bị ảnh hưởng, rollback ngay, không chờ.

---

## Rủi ro đã biết

| Rủi ro | Xác suất | Xử lý |
|---|---|---|
| Egress proxy crash → `checkout` không gọi MSK/DynamoDB | Thấp (Envoy stable) | Rollback Phase 1 |
| Domain thiếu trong allowlist → service timeout | Trung bình | Thêm domain vào `egressProxy.allowedDomains` |
| `initContainers` bị block egress | Thấp | Template đã có VPC CIDR fallback rule |
| AWS SDK calls không đi qua proxy | Trung bình | Verify HTTPS_PROXY env var được inject |
