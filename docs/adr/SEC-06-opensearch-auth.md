# ADR SEC-06: Bật OpenSearch Security Plugin — bảo vệ log store

- **Status:** Accepted
- **Date:** 2026-07-13
- **Author:** CDO-03 (TF2)
- **Trụ:** Security + Auditability

---

## Bối cảnh

OpenSearch là data plane duy nhất lưu trữ toàn bộ application logs của hệ thống (18+ service qua OTel Collector). Trong quá trình điều tra incident, đây là nguồn bằng chứng không thể thay thế.

Trạng thái trước khi thay đổi:

```yaml
# values.yaml — components.opensearch.env
- name: DISABLE_SECURITY_PLUGIN
  value: "true"
```

Hậu quả của `DISABLE_SECURITY_PLUGIN: "true"`:
- Không có authentication — bất kỳ pod nào trong cluster đều đọc/ghi/xoá được log qua `opensearch:9200`
- Không có authorization — không phân biệt read-only vs write-only access
- Không có audit log tại OpenSearch — không biết ai query/thay đổi gì
- Log của incident có thể bị xoá hoặc tamper trước khi team điều tra xong

Kết hợp với việc không có NetworkPolicy trong chart, OpenSearch port 9200 hoàn toàn mở với mọi workload trong namespace.

---

## Quyết định

**Bật OpenSearch Security Plugin** bằng cách xoá `DISABLE_SECURITY_PLUGIN: "true"` và:
1. Inject `OPENSEARCH_INITIAL_ADMIN_PASSWORD` từ K8s Secret (ESO-synced) để bootstrap admin user khi node khởi động lần đầu
2. Giữ `DISABLE_INSTALL_DEMO_CONFIG: "false"` để OpenSearch tạo demo self-signed TLS certs (security plugin **bắt buộc** có SSL material lúc load; nếu `true` mà không mount PEM riêng → `No SSL configuration found` / CrashLoopBackOff)
3. OTel Collector và Grafana gọi `https://opensearch:9200` với basic auth + skip TLS verify (cluster-internal)
4. Quản lý credential qua `secrets-chart` (ESO pattern đã có từ SEC-05)

**Yêu cầu mật khẩu admin (OpenSearch):** ≥8 ký tự, có chữ hoa, chữ thường, số, **và ký tự đặc biệt**.

---

## Lý do chọn giải pháp này

| Tiêu chí | Lý do |
|---|---|
| Không thay đổi kiến trúc | Security plugin là built-in của OpenSearch — chỉ cần bật, không cần component mới |
| Phù hợp pattern SEC-05 | Credential qua ESO + ASM — không hardcode, có audit trail CloudTrail |
| Không ảnh hưởng SLO | OTel Collector và Grafana vẫn kết nối được sau khi cập nhật credential |
| Bảo vệ dữ liệu điều tra | Sau khi bật, chỉ collector (write) và Grafana (read) mới có quyền truy cập |

---

## Thay đổi

### `secrets-chart/templates/externalsecrets.yaml`
- Thêm `ExternalSecret` mới cho `techx-corp-opensearch`
- Map ASM `opensearch.username`, `opensearch.password` → ba key: `username`, `password`, `OPENSEARCH_INITIAL_ADMIN_PASSWORD`

### `secrets-chart/values.yaml`
- Thêm target `opensearch: techx-corp-opensearch`

### `values.yaml` — `components.opensearch.env`
- Xoá `DISABLE_SECURITY_PLUGIN: "true"`
- Đặt `DISABLE_INSTALL_DEMO_CONFIG: "false"` (demo TLS certs cho single-node; không dùng `true` khi security bật trừ khi đã mount PEM)
- Thêm `OPENSEARCH_INITIAL_ADMIN_PASSWORD` từ `secretKeyRef`

### `values.yaml` — `opentelemetry-collector`
- Thêm `extraEnvs`: `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD` từ `secretKeyRef`
- Thêm `extensions.basicauth/opensearch` trong collector config
- Cập nhật `opensearch` exporter: `auth.authenticator: basicauth/opensearch`
- Thêm `extensions: [basicauth/opensearch]` vào `service`

### `values.yaml` — `grafana`
- Thêm `envValueFrom`: `OPENSEARCH_USERNAME`, `OPENSEARCH_PASSWORD` từ `secretKeyRef`

### `grafana/provisioning/datasources/opensearch.yaml`
- Thêm `basicAuth: true`, `basicAuthUser: ${OPENSEARCH_USERNAME}`, `secureJsonData.basicAuthPassword: ${OPENSEARCH_PASSWORD}`

### `docs/operations/external-secrets.md`
- Thêm hướng dẫn bootstrap ASM secret `opensearch` và verify step

---

## Thứ tự deploy (quan trọng)

```
1. Bootstrap ASM secret:
   aws secretsmanager put-secret-value \
     --secret-id techx-corp/<env>/opensearch \
     --secret-string '{"username":"admin","password":"<strong-24char>"}'

2. helm upgrade techx-corp-secrets ./secrets-chart ...
   kubectl wait --for=condition=Ready externalsecret/techx-corp-opensearch

3. helm upgrade techx-corp ./ ...
   → OpenSearch pod restart: security plugin active, admin password set
   → Collector restart: basicauth extension loads credentials
   → Grafana restart: datasource uses basicAuth

4. Verify:
   kubectl -n <ns> exec -it statefulset/opensearch -- \
     curl -sk -u admin:<password> https://localhost:9200/_cluster/health
   # expect: {"status":"green"} or "yellow" (single-node normal)
```

**Lưu ý:** OpenSearch với security plugin bật sẽ khởi động chậm hơn (~30s thêm) do TLS handshake setup nội bộ. `startupProbe.failureThreshold: 36` hiện tại đủ dư cho điều này. Clients (collector, Grafana) phải dùng **HTTPS** (demo cert → `tls.insecure` / `tlsSkipVerify`).

---

## Rủi ro

| Rủi ro | Xác suất | Mức độ | Giảm thiểu |
|---|---|---|---|
| Secret chưa tạo trước khi deploy OpenSearch | Cao | Cao | Deploy secrets-chart và wait Ready trước app chart |
| Collector không thể write nếu credential sai | Trung bình | Cao | Verify `kubectl logs` collector sau deploy; rollback nếu lỗi |
| OpenSearch cold start chậm hơn sau khi bật plugin | Cao | Thấp | `startupProbe` với `failureThreshold: 36` (~6.5 phút) đủ dư |
| Password rotation làm gián đoạn logs | Thấp | Trung bình | Rotate theo thứ tự: ASM → wait ESO → rollout restart collector |

---

## Rollback

```bash
# 1. Khôi phục DISABLE_SECURITY_PLUGIN trong values.yaml
# 2. Xoá OPENSEARCH_INITIAL_ADMIN_PASSWORD env
# 3. Xoá extraEnvs / envValueFrom liên quan đến opensearch
# 4. Khôi phục opensearch.yaml datasource về không có basicAuth
# 5. helm upgrade lại
# 6. Nếu PVC đã có data với security bật, cần reset bằng cách xoá PVC và để OpenSearch tạo lại
```

---

## Tham chiếu

- `docs/adr/SEC-05-remove-hardcoded-credentials.md` — ESO pattern
- `docs/operations/external-secrets.md` — bootstrap runbook
- `secrets-chart/templates/externalsecrets.yaml` — ExternalSecret opensearch
- OpenSearch Security Plugin docs: https://opensearch.org/docs/latest/security/
