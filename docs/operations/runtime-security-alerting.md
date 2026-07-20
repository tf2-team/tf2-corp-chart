# Runtime Security Alerting

Mandate 05 runtime hardening uses native Kubernetes admission to deny new unsafe workload specs. The runtime-hardening inventory CronJob adds drift detection for objects that already exist or somehow bypass admission.

## Signals Covered Now

- `RuntimeHardeningInventoryViolation`: the scheduled scanner found a violating workload or the scanner failed before it could prove the cluster clean.
- `RuntimeHardeningInventoryMissedSchedule`: the scanner did not run within the expected window.

The scanner uses a dedicated ServiceAccount with only `get/list` on Pods, replication controllers, Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. It does not read Secrets, exec into Pods, create workloads, patch workloads or delete workloads.

## Triage

```powershell
kubectl -n techx-corp-prod get cronjob runtime-hardening-inventory
kubectl -n techx-corp-prod get jobs -l app.kubernetes.io/component=runtime-hardening-inventory --sort-by=.metadata.creationTimestamp
kubectl -n techx-corp-prod logs job/<latest-runtime-hardening-inventory-job>
```

The Job log is a sanitized JSON summary. It must not contain Secret data, tokens, request bodies or credentials.

## Expected Clean Output

```json
{
  "status": "pass",
  "cluster": "techx-tf2-prod",
  "environment": "production",
  "checkedObjects": 42,
  "checkedContainers": 83,
  "violationCount": 0,
  "violations": []
}
```

## Alert Routing

Grafana sends these alerts through the existing Discord contact point. This reuses the existing notification path and does not add a new always-on service.

## Rollback

If the scanner is noisy or broken, suspend only the CronJob:

```powershell
kubectl -n techx-corp-prod patch cronjob runtime-hardening-inventory -p '{"spec":{"suspend":true}}'
```

Do not disable EKS audit logs, CloudTrail or runtime-hardening admission while tuning the scanner.
