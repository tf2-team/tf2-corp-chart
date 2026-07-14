# Change: SEC-06 — Bật OpenSearch Security Plugin (bảo vệ log store)

## Summary

Bật OpenSearch security plugin bằng cách xoá `DISABLE_SECURITY_PLUGIN: "true"` và wiring credential qua ESO pattern (SEC-05). OTel Collector và Grafana cập nhật để dùng basic auth. Log store không còn mở public trong cluster.

## Context

OpenSearch là data plane duy nhất lưu log của 18+ service. Với `DISABLE_SECURITY_PLUGIN: "true"`, bất kỳ pod nào trong namespace đều có thể đọc, ghi hoặc xoá log qua `opensearch:9200` mà không cần credential. Điều này làm log dùng để điều tra incident không đáng tin cậy.

## Before

```yaml
# components.opensearch.env
- name: DISABLE_SECURITY_PLUGIN
  value: "true"
```
- Không authentication, không authorization tại OpenSearch
- Grafana datasource và OTel Collector kết nối anonymous (không credential)

## After

```yaml
# components.opensearch.env — DISABLE_SECURITY_PLUGIN removed
- name: OPENSEARCH_INITIAL_ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: techx-corp-opensearch
      key: OPENSEARCH_INITIAL_ADMIN_PASSWORD
```
- Security plugin active; admin user bootstrapped từ ESO Secret
- OTel Collector dùng `basicauth/opensearch` extension (OPENSEARCH_USERNAME/PASSWORD từ Secret)
- Grafana datasource dùng `basicAuth: true` (envValueFrom Secret)
- Credential quản lý qua `secrets-chart` ESO → AWS Secrets Manager

## Technical Design Decisions

- **Dùng built-in security plugin** thay vì giải pháp external: không cần component mới, plugin đã bundled trong OpenSearch image
- **Single admin user** cho cả collector (write) và Grafana (read): đủ cho giai đoạn hiện tại; tách thành 2 user riêng nếu cần least-privilege cao hơn
- **Credential qua ESO** (SEC-05 pattern): nhất quán với cách quản lý credential trong dự án, có CloudTrail audit trail
- **Không thêm NetworkPolicy** trong PR này: tách thành task riêng để giữ blast radius nhỏ

## Implementation Details

1. Xoá `DISABLE_SECURITY_PLUGIN: "true"` khỏi `components.opensearch.env`
2. Thêm `OPENSEARCH_INITIAL_ADMIN_PASSWORD` secretKeyRef vào opensearch env
3. Thêm `ExternalSecret` cho `techx-corp-opensearch` vào `secrets-chart/templates/externalsecrets.yaml`
4. Thêm target `opensearch` vào `secrets-chart/values.yaml`
5. Thêm `extensions.basicauth/opensearch` + `service.extensions` vào otel-collector config
6. Thêm `extraEnvs` (OPENSEARCH_USERNAME/PASSWORD) vào otel-collector
7. Cập nhật opensearch exporter: `auth.authenticator: basicauth/opensearch`
8. Thêm `envValueFrom` (OPENSEARCH_USERNAME/PASSWORD) vào grafana
9. Cập nhật `grafana/provisioning/datasources/opensearch.yaml` với `basicAuth: true`
10. Bổ sung bootstrap step OpenSearch vào `docs/operations/external-secrets.md`
11. Tạo ADR `docs/adr/SEC-06-opensearch-auth.md`

## Files Changed

**Chart:**
- `values.yaml` — opensearch env, otel-collector extraEnvs + extensions, grafana envValueFrom
- `grafana/provisioning/datasources/opensearch.yaml` — basicAuth fields

**Secrets chart:**
- `secrets-chart/templates/externalsecrets.yaml` — ExternalSecret opensearch
- `secrets-chart/values.yaml` — target opensearch

**Docs:**
- `docs/adr/SEC-06-opensearch-auth.md` — ADR
- `docs/operations/external-secrets.md` — bootstrap + verify steps
- `docs/changes/2026-07-13-sec-06-opensearch-security-plugin.md` — this change record

## Dependencies and Cross-Repository Impact

- Depends on ASM secret `techx-corp/<env>/opensearch` bootstrapped before deploy
- No infra (Terraform) change required — ESO IRSA role đã có `GetSecretValue` trên prefix `techx-corp/*`

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Storefront / checkout không thay đổi — không component nào gọi OpenSearch trực tiếp |
| **Observability** | Logs vẫn chạy qua OTel Collector → OpenSearch (với auth). Grafana vẫn đọc được sau khi env reload |
| **Deployment** | Cần bootstrap ASM secret trước; OpenSearch pod restart (~30s chậm hơn cold start) |
| **Backward compatibility** | Nếu rollback: xoá PVC nếu security plugin đã ghi metadata vào data dir |

## Validation

### Automated Checks

| Check | Command | Expected |
|---|---|---|
| Helm lint | `helm lint .` | No errors |
| Helm template | `helm template test . -f values.yaml \| grep DISABLE_SECURITY` | No output |
| ExternalSecret ready | `kubectl wait --for=condition=Ready externalsecret/techx-corp-opensearch` | condition met |

### Manual Verification

```bash
# 1. OpenSearch health với auth
kubectl -n <ns> exec -it statefulset/opensearch -- \
  curl -sk -u admin:<password> http://localhost:9200/_cluster/health | grep status
# expect: "green" or "yellow"

# 2. Collector đang write log
kubectl -n <ns> logs daemonset/otel-collector | grep -i opensearch
# expect: no auth error

# 3. Grafana đọc được OpenSearch
# Mở Grafana → Explore → datasource OpenSearch → query logs
```

## Migration or Deployment Notes

1. Tạo ASM secret trước: `aws secretsmanager put-secret-value --secret-id techx-corp/<env>/opensearch --secret-string '{"username":"admin","password":"<24char>"}'`
2. Deploy `techx-corp-secrets` chart trước, wait Ready
3. Deploy `techx-corp` chart
4. Nếu OpenSearch PVC đã có data từ lần chạy không có security: pod sẽ fail do config mismatch — cần xoá PVC để init lại từ đầu (mất historical logs, chấp nhận được vì log là observability data, không phải business data)

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation |
|---|---|---|---|
| PVC data dir conflict (security plugin metadata vs non-security) | High (nếu PVC đã tồn tại) | Medium | Xoá PVC trước deploy; document trong ADR |
| Collector credential sai → log pipeline bị gián đoạn | Low | High | Verify ngay sau deploy; rollback nhanh bằng helm rollback |

**Rollback:** Khôi phục `DISABLE_SECURITY_PLUGIN: "true"`, xoá các secret/env thêm vào, `helm upgrade` lại. Xem ADR SEC-06 mục Rollback.
