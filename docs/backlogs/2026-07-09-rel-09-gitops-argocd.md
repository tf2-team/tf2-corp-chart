# Backlog: REL-09 - GitOps Argo CD (Helm chart level)

## Bối cảnh

Chart `techx-corp-chart` là desired state deploy lên EKS. Cần lớp GitOps để Argo CD sync Application thay cho `helm upgrade` thủ công, kèm values theo môi trường và quy tắc promote image an toàn.

Kế hoạch: [`docs/gitops-argocd.md`](../../../docs/gitops-argocd.md) · Runbook: [`docs/operations/gitops-argocd.md`](../operations/gitops-argocd.md)

## Vấn đề

1. Deploy phụ thuộc CLI `--set image.tag` — dễ lệch Git.  
2. Global tag + bake thiếu service → ImagePullBackOff.  
3. Bảo vệ chỉ `values-prod.yaml` không đủ khi Application `path: .`.  
4. Cần quy định rollback Git-first và không dual-drive Helm.

## Giải pháp (chart)

1. `values-dev.yaml` / `values-prod.yaml` — repository + tag + ALB posture.  
2. `gitops/clusters/{dev,prod}/` — AppProject (whitelist CR/CRB/Namespace) + Application (sync thủ công, không SSA).  
3. Runbook: wait 600s, Git revert primary, history break-glass.  
4. CODEOWNERS / branch protection gợi ý cho mọi path ảnh hưởng prod.  
5. Không app-of-apps trong v1 (Phase 7).

## Acceptance Criteria

- [ ] values-dev/prod tồn tại; comment contract rebuild-all.  
- [ ] Application dev/prod: valueFiles đúng; auto-sync OFF; prune OFF; không ServerSideApply.  
- [ ] AppProject: destination chỉ `techx-corp`; clusterResourceWhitelist cụ thể.  
- [ ] Runbook có sync --dry-run, wait --timeout 600, rollback Git, break-glass history.  
- [ ] Tài liệu prod path protection đầy đủ.

## Kiểm thử

```sh
helm template techx-corp . -f values-public-alb.yaml -f values-dev.yaml
argocd app sync techx-corp --dry-run
argocd app wait techx-corp --sync --health --timeout 600
```

## Rủi ro & rollback

Dual Helm/Argo → cấm helm thường sau cutover.  
Partial sync → Git revert + wait health.  
**Rollback chuẩn:** git revert.

---

## English Summary

Chart-level REL-09: env value overlays, inventory-based AppProject, manual-first Applications without SSA, and operator runbook with Git-primary rollback.
