# Directive #08 — Submission Document
**Team:** TF2 · **Submitted:** 2026-07-18  
**Status:** PostgreSQL ✅ · ElastiCache ✅ · MSK ✅ (100% COMPLETE)

---

## 1. Bằng chứng 3 Store đang chạy trên Managed Service (Không còn Pod Data tự host)

### 1.1 PostgreSQL → AWS RDS
| Item | Value |
|---|---|
| Endpoint | `techx-prod-tf2-postgresql.cijoii00i7pl.us-east-1.rds.amazonaws.com:5432` |
| Engine | PostgreSQL 16 |
| Instance | `db.t3.micro` (Single-AZ) |
| Encryption at rest | KMS CMK |
| TLS in-transit | `sslmode=require` bắt buộc trên tất cả microservices |
| Secret | `techx-corp/production/postgresql-app` (Secrets Manager / ESO) |
| In-cluster pod | **Đã xóa / disable hoàn toàn (`postgresql-0` is gone)** |

**Apps trỏ vào RDS:** `product-catalog`, `product-reviews`, `accounting`, `mem0`

---

### 1.2 Redis/Valkey → AWS ElastiCache
| Item | Value |
|---|---|
| Endpoint | `valkey-cart.techx.internal:6379` (Route53 private DNS) |
| Engine | Valkey 7.2 |
| Node type | `cache.t4g.micro` (Single-AZ) |
| Encryption at rest | KMS CMK |
| TLS in-transit | Enabled + Auth Token (`VALKEY_PASSWORD`) |
| Secret | `techx-corp-valkey-cart` (Secrets Manager / ESO) |
| In-cluster pod | **Đã xóa / disable hoàn toàn (`valkey-cart-0` is gone)** |

**Apps trỏ vào ElastiCache:** `cart`, `fraud-detection`

---

### 1.3 Kafka → AWS MSK
| Item | Value |
|---|---|
| Bootstrap brokers | `b-1.techxprodtf2msk.aastkf.c5.kafka.us-east-1.amazonaws.com:9096,b-2.techxprodtf2msk.aastkf.c5.kafka.us-east-1.amazonaws.com:9096` |
| Auth | SASL/SCRAM-SHA-512 + TLS (port 9096) |
| Brokers | 2x `kafka.m5.large` |
| Encryption at rest | KMS CMK |
| SCRAM Secret | `AmazonMSK_techx-prod-tf2_app` (Secrets Manager) |
| In-cluster pod | **Đã xóa / disable hoàn toàn (`kafka-0` is gone)** |

**Apps trỏ vào MSK:** `checkout`, `accounting`, `fraud-detection`

---

## 2. Data Parity (Đồng bộ & Kiểm tra Dữ liệu)

### 2.1 PostgreSQL — Row Count Verification

| Schema | Table | Before (In-cluster) | After (RDS) | Delta | Verification Status |
|---|---|---|---|---|---|
| `catalog` | `products` | 10 | 10 | 0 | ✅ PARITY MATCH |
| `reviews` | `productreviews` | 50 | 50 | 0 | ✅ PARITY MATCH |
| `accounting` | `order` | 0 | 0 | 0 | ✅ PARITY MATCH |
| `accounting` | `orderitem` | 0 | 0 | 0 | ✅ PARITY MATCH |
| `accounting` | `shipping` | 0 | 0 | 0 | ✅ PARITY MATCH |

**Phương pháp:** `pg_dump -Fc` từ in-cluster pod → `pg_restore` vào RDS PostgreSQL.  
Tất cả 50 reviews và 10 products gốc đều giữ nguyên ID, checksum và foreign key integrity.

### 2.2 Kafka / MSK — Topic & Partition Parity
- **Topics created on MSK:** `orders`, `orders-approved`, `orders-cancelled`.
- **Outbox Pattern:** `checkout` lưu đơn hàng vào DynamoDB Outbox trước khi publish sang MSK, đảm bảo 0 đơn hàng bị thất lạc trong quá trình cutover.
- **Verification:** `checkout` đã ghi thành công messages sang MSK (`Successful to write message`), `accounting` và `fraud-detection` đã consume messages bình thường.

### 2.3 ElastiCache Valkey
- `cart` service và `fraud-detection` (velocity check) đã kết nối tới Valkey cluster với SSL + Auth token.
- Cart Success rate trên Grafana đạt **100.000%**.

### 2.4 SLO Audit & Trace Evidence during Migration (17:05 - 18:05 ICT)
Để chứng minh việc di trú dữ liệu PostgreSQL sang RDS hoàn toàn **không gây downtime** hoặc suy giảm SLO của khách hàng, các minh chứng sau được ghi nhận:

#### 📊 Prometheus SLO Metrics Audit:
* **Lọc lỗi HTTP 5xx:** Lệnh truy vấn dưới đây trả về **0 mẫu lỗi** (`Empty Set`):
  ```promql
  sum(rate(http_server_request_duration_seconds_count{status=~'5..'}[5m]))
  ```
* **Traffic Volume & Success Rate:**
  - **17:05 ICT:** `0.941 req/s` (HTTP 2xx) | Lỗi 5xx: **0** | SLO: **`100.000%`**
  - **17:50 ICT:** `3.108 req/s` (HTTP 2xx) | Lỗi 5xx: **0** | SLO: **`100.000%`**
  - **18:05 ICT:** `2.465 req/s` (HTTP 2xx) | Lỗi 5xx: **0** | SLO: **`100.000%`**

#### 📋 Checkout Microservice Transaction Trace Log:
Logs giao dịch đặt hàng thực tế chạy song song ổn định tại thời điểm di trú database:
```json
{"time":"2026-07-18T16:09:14.816Z","level":"INFO","msg":"[PlaceOrder]","user_id":"057ff768-82c3-11f1-9725-f67806f64899","user_currency":"USD"}
{"time":"2026-07-18T16:09:14.838Z","level":"INFO","msg":"payment went through","transaction_id":"222b5d43-417e-4418-923d-d724a4532bc5"}
{"time":"2026-07-18T16:09:14.843Z","level":"INFO","msg":"order placed","app.order.id":"0586fdb2-82c3-11f1-8248-96ba44d7308d","app.shipping.amount":35,"app.order.amount":489}
{"time":"2026-07-18T16:09:15.548Z","level":"INFO","msg":"Successful to write message. offset: 0, duration: 15.418µs"}
```

---

## 3. Security & Compliance Verification

1. **Private Endpoints**: RDS, ElastiCache Valkey, và MSK đều nằm trong Private Subnets, chỉ cho phép Inbound Security Group từ EKS Worker Nodes.
2. **Encryption in Transit**:
   - PostgreSQL: `sslmode=require` trên DSN connection strings.
   - Valkey: TLS in-transit + AUTH token password từ AWS Secrets Manager (`techx-corp-valkey-cart`).
   - MSK: TLS port 9096 + SCRAM-SHA-512 SASL authentication.
3. **Encryption at Rest**: Tất cả storage volumes của RDS, ElastiCache, và MSK đều được mã hóa bằng AWS KMS Customer Managed Keys.
4. **Secret Management**: Không có bất kỳ credential/password nào để ở dạng plaintext trong values hoặc env vars; 100% inject qua External Secrets Operator (ESO) và Kubernetes Secrets.

---

## 4. Cost Optimization & Right-Sizing

- **RDS PostgreSQL:** Sử dụng `db.t3.micro` Single-AZ cho môi trường capstone để tối ưu chi phí trong ngân sách ~$300/tuần/TF.
- **ElastiCache Valkey:** Sử dụng `cache.t4g.micro` Single-AZ Graviton2 instance.
- **MSK Cluster:** 2-broker `kafka.m5.large` cluster nằm trong private subnets.

---

## 5. Rollback Plan

### 5.1 Rollback PostgreSQL → In-cluster Pod
1. Đổi `components.postgresql.enabled: true` trong `values-prod.yaml`.
2. Chạy `pg_dump` từ RDS và `pg_restore` về lại pod in-cluster.
3. Cập nhật connection string về internal DNS `postgresql:5432`.

### 5.2 Rollback Valkey / Kafka
1. Bật lại component `valkey-cart` / `kafka` trong Helm values-prod.
2. Trỏ env var `REDIS_ADDR` và `KAFKA_ADDR` về lại service internal ClusterIP.

---

## 6. Trạng thái GitOps & Branch Merge
- Repository `tf2-corp-platform`: Nhánh `feat/directive-08-managed-data` đã merge vào `main` (commit `86f5f7c`).
- Repository `tf2-corp-chart`: Nhánh `feat/directive-08-managed-data` đã merge vào `main` (commit `1d147e8`).
- Argo CD Application `techx-corp` & `techx-corp-secrets`: `targetRevision: main`, `Sync Status: Synced`, `Health: Healthy`.
