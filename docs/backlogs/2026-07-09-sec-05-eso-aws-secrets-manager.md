# Backlog: SEC-05 - Đồng bộ credential từ AWS Secrets Manager qua ESO (Helm chart level)

## Bối cảnh

Helm chart `techx-corp-chart` hiện inject nhiều credential dạng plaintext trong `values.yaml` (connection string Postgres, `SECRET_KEY_BASE`, `OPENAI_API_KEY`, Grafana `adminPassword`, v.v.). Để đáp ứng SEC-05, chart cần tiêu thụ secret đã được External Secrets Operator (ESO) đồng bộ từ AWS Secrets Manager xuống Kubernetes Secret, thay vì lưu password production trong Git.

Kế hoạch tổng thể (cross-repo): [`docs/eso-aws-secrets-manager.md`](../../../docs/eso-aws-secrets-manager.md)  
Backlog tổng: [`docs/backlogs/2026-07-09-sec-05-eso-aws-secrets-manager.md`](../../../docs/backlogs/2026-07-09-sec-05-eso-aws-secrets-manager.md)

**Phụ thuộc:** infra đã có ASM metadata, IRSA ESO, ESO đã cài, `ClusterSecretStore` Ready (phần infra của SEC-05).

## Vấn đề

1. `components.*.env` dùng `value:` chứa password/DSN nhạy cảm.
2. ConfigMap `postgresql-init` nhúng `PASSWORD 'otelp'` từ `postgresql/init.sql`.
3. Grafana subchart nhận admin password từ values plaintext.
4. Không có `ExternalSecret` / release secrets; deploy app có thể race với việc tạo Secret.
5. Sau cutover, dual-mode plaintext nếu giữ lâu sẽ mâu thuẫn mục tiêu “không credential production trong Git”.

## Giải pháp đề xuất

1. **ExternalSecret (ưu tiên release riêng `techx-corp-secrets`)**  
   - Map ASM → K8s Secret: `techx-corp-postgresql-admin`, `techx-corp-postgresql-app`, flagd-ui, product-reviews, grafana-admin.  
   - `target.creationPolicy: Orphan` trong giai đoạn migration; kiểm tra hành vi với version ESO đã pin.  
   - Deploy order: secrets release → `kubectl wait --for=condition=Ready externalsecret` → app release.

2. **Chuyển consumer sang `secretKeyRef`** (Phase cutover — **không đổi password**):  
   - accounting / product-catalog / product-reviews: `DB_CONNECTION_STRING`  
   - postgresql: `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`  
   - flagd-ui: `SECRET_KEY_BASE`  
   - product-reviews: `OPENAI_API_KEY`  
   - Grafana: `admin.existingSecret`

3. **DSN template**  
   - Giữ đúng format hiện tại (.NET / postgres URL / libpq).  
   - Password alphabet an toàn khi ghép chuỗi; document trong runbook.

4. **`values-demo.yaml`**  
   - Chứa credential demo local.  
   - `values.yaml` production path fail-safe, không default password giống production.

5. **Sau cutover ổn định**  
   - Gỡ plaintext production khỏi values/SQL (trong phạm vi an toàn với PVC đã init).  
   - Runbook: bootstrap, cutover, rotate + **rollout restart**, rollback (helm rollback app + giữ Secret).  
   - Cân nhắc gitleaks/secret scanning.

6. **Tận dụng sẵn có**  
   - `_pod.tpl` / env merge đã render được `valueFrom.secretKeyRef`.  
   - `values.schema.json` đã có schema `secretKeyRef`.

## Acceptance Criteria

- [ ] Có manifest/template ExternalSecret (hoặc chart secrets) map đúng remote key ASM → Secret name/key ổn định.
- [ ] Production path: env nhạy cảm dùng `secretKeyRef`, không `value:` password production.
- [ ] Deploy có bước chờ ExternalSecret Ready (hoặc hai release rõ ràng).
- [ ] Grafana dùng `existingSecret` do ESO tạo.
- [ ] `values-demo.yaml` cho demo; sau migration không còn plaintext production trong base values.
- [ ] Runbook operations mô tả cutover, rotate, restart pod, rollback.
- [ ] `helm lint` / `helm template` thành công; smoke test pass sau cutover.

## Kiểm thử / xác minh

```sh
# Template: có secretKeyRef, không còn otelp/admin production trong overlay prod
helm template techx-corp . -f values.yaml  # (+ overlay ESO nếu có)

kubectl -n techx-corp wait --for=condition=Ready externalsecret --all --timeout=120s

helm upgrade --install techx-corp . -n techx-corp --wait --atomic --timeout 15m
./scripts/smoke-test.sh

kubectl -n techx-corp logs deploy/accounting --tail=50
kubectl -n techx-corp logs deploy/product-catalog --tail=50
kubectl -n techx-corp logs deploy/product-reviews --tail=50
```

## Rủi ro & rollback

- **Rủi ro**: `CreateContainerConfigError` nếu Secret chưa Ready; DSN hỏng nếu password có ký tự đặc biệt; xóa ExternalSecret với `creationPolicy: Owner` có thể GC Secret.
- **Rollback**: `helm rollback` app; giữ ExternalSecret/K8s Secret. **Không** khôi phục plaintext production vào Git sau cutover. Dual-mode plaintext chỉ tạm trong PR migration.

---

## English Summary

Chart-level SEC-05 work: ExternalSecret resources (prefer separate secrets release), switch sensitive env to `secretKeyRef`, Grafana `existingSecret`, demo isolation via `values-demo.yaml`, and operations runbook. Depends on infra ESO/ASM foundation. Full plan in workspace `docs/eso-aws-secrets-manager.md`.
