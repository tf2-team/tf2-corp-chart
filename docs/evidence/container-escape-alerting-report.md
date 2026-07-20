# Container Escape Alerting Report

Status: pending production verification.

## Scope

This report tracks Mandate 05 alerting for container escape and runtime-hardening drift. It covers scheduled inventory and Grafana/Discord alert routing. GuardDuty Runtime Monitoring, EKS audit-log classifiers and node-role anomaly classifiers require separate infra approval before they can be marked complete.

## Evidence Checklist

| Gate | Command | Expected result | Evidence |
| --- | --- | --- | --- |
| CronJob rendered | `helm template techx-corp . -n techx-corp-prod -f values-prod.yaml \| sls 'runtime-hardening-inventory'` | CronJob, ServiceAccount, RBAC and ConfigMap render | Screenshot after command |
| RBAC read-only | `kubectl auth can-i --as system:serviceaccount:techx-corp-prod:runtime-hardening-inventory list pods --all-namespaces` | `yes` | Screenshot |
| No write RBAC | `kubectl auth can-i --as system:serviceaccount:techx-corp-prod:runtime-hardening-inventory create pods -n techx-corp-prod` | `no` | Screenshot |
| Inventory clean | `kubectl -n techx-corp-prod create job --from=cronjob/runtime-hardening-inventory runtime-hardening-inventory-manual; kubectl -n techx-corp-prod logs job/runtime-hardening-inventory-manual` | JSON `status: pass`, `violationCount: 0` | Screenshot/log |
| Missed-scan alert | Temporarily suspend CronJob in a non-prod test or approved window | Grafana alert `RuntimeHardeningInventoryMissedSchedule` fires | Screenshot |
| Violation alert | Use approved non-prod fixture or controlled prod dry run path | Grafana alert `RuntimeHardeningInventoryViolation` fires | Screenshot |
| Post-check | `kubectl get pods -A; kubectl -n argocd get applications` | No new regression; Argo CD Healthy/Synced | Screenshot |

## Result

Fill after production verification.
