# Backlog: REL-09 - GitOps Argo CD (Helm chart level)

## Bối cảnh

Helm chart `techx-corp-chart` là desired state của platform trên EKS. Hiện deploy chủ yếu bằng `helm upgrade` thủ công. REL-09 yêu cầu lớp GitOps: Argo CD Application trỏ chart + valueFiles theo môi trường, kèm quy tắc promote image và rollback an toàn.

- Kế hoạch tổng: [`docs/gitops-argocd.md`](../../../docs/gitops-argocd.md)
- Backlog tổng: [`docs/backlogs/2026-07-09-rel-09-gitops-argocd.md`](../../../docs/backlogs/2026-07-09-rel-09-gitops-argocd.md)
- Runbook: [`docs/operations/gitops-argocd.md`](../operations/gitops-argocd.md)

**Phụ thuộc:** Argo CD control plane đã cài (infra REL-09, `argocd_enabled=true`).

## Vấn đề

1. Image tag / repo không nằm ổn định trong Git theo env (`--set` rời rạc).
2. Application `path: .` → mọi thay đổi chart (không chỉ values-prod) có thể deploy production.
3. Global `default.image.tag` + bake thiếu service → ImagePullBackOff.
4. Cần quy định ownership Argo sau cutover (không dual Helm).
5. Rollback History khi auto-sync bật sẽ conflict nếu không cập nhật Git.

## Giải pháp đề xuất (chart)

1. **`values-dev.yaml` / `values-prod.yaml`**  
   - `default.image.repository` + `tag`  
   - ALB `blockSensitivePaths` theo env  
   - Comment contract: rebuild-all cùng tag trước khi đổi tag  

2. **`gitops/clusters/{dev,prod}/`**  
   - `AppProject`: destination `techx-corp`; whitelist ClusterRole, ClusterRoleBinding, Namespace  
   - `Application`: valueFiles = base + public-alb + env; **không** ServerSideApply  
   - Default: `automated` + `selfHeal: true`; prune OFF  

3. **Runbook**  
   - `sync --dry-run` → `sync` → `wait --timeout 600` → smoke  
   - Rollback chuẩn = git revert  
   - History rollback = break-glass + cập nhật Git  

4. **`CODEOWNERS`**  
   - Cover templates, charts, Chart.*, values.yaml, values-prod*, values-public-alb, gitops/clusters/prod, postgresql  

5. **Không app-of-apps trong v1** (đánh giá Phase 7).

## Acceptance Criteria

- [ ] `values-dev.yaml` / `values-prod.yaml` tồn tại và document image contract.
- [ ] AppProject + Application dev/prod trong `gitops/clusters/`.
- [ ] Baseline Application: no SSA; auto-sync + self-heal; prune OFF.
- [ ] AppProject không cho destination `argocd`; whitelist cluster-scoped cụ thể.
- [ ] Runbook đầy đủ: ownership, rollback Git, break-glass, promote verify ECR.
- [ ] CODEOWNERS (hoặc tương đương) cho path ảnh hưởng prod.
- [ ] DEPLOYMENT.md / README nêu GitOps là đường chính; Helm là break-glass.

## Kiểm thử / xác minh

```sh
helm template techx-corp . \
  -f values-public-alb.yaml -f values-dev.yaml >/dev/null

kubectl apply -f gitops/clusters/dev/   # sau khi Argo CD sẵn sàng
argocd app diff techx-corp
argocd app sync techx-corp --dry-run
argocd app sync techx-corp
argocd app wait techx-corp --sync --health --timeout 600
./scripts/smoke-test.sh --namespace techx-corp
```

## Rủi ro & rollback

| Rủi ro | Giảm thiểu |
|--------|------------|
| Drift first sync | Snapshot tag live vào values-* trước cutover |
| Dual Helm/Argo | Cấm helm thường sau cutover |
| Partial sync | wait health; Git revert |
| Prod path lọt review | CODEOWNERS rộng |

**Rollback chuẩn:** `git revert` → merge → Argo sync.

---

## English Summary

Chart-level REL-09: env value overlays, inventory-based AppProject, manual-first Applications without ServerSideApply, CODEOWNERS for prod-affecting paths, and operator runbook with Git-primary rollback.
