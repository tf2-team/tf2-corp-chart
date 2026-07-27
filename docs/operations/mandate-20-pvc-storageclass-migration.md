# Mandate 20 PVC StorageClass migration

## Objective

Move operational PVCs from `gp3-encrypted` to
`gp3-encrypted-m20` gradually. Both StorageClasses remain available during the
migration. Existing PVCs are never patched in place because
`spec.storageClassName` is immutable.

## Current posture

- Existing production volumes are encrypted, tagged
  `Mandate20Backup=hourly`, and have completed recovery points.
- `gp3-encrypted` remains the StorageClass for current PVCs.
- `gp3-encrypted-m20` applies encryption and the hourly backup-selection tag to
  newly provisioned production volumes.

There is no Mandate 20 requirement to migrate a healthy PVC solely to change
its StorageClass name. Migrate only during an approved workload maintenance
change or when a PVC must otherwise be replaced.

## Per-workload procedure

1. Record the source PVC, PV, EBS volume ID, size, AZ, filesystem, and current
   backup recovery point.
2. Create an additional application-consistent snapshot or backup and wait for
   `COMPLETED`.
3. Create a new PVC with a distinct name and
   `storageClassName: gp3-encrypted-m20`. Do not delete or patch the source PVC.
4. Restore/copy data using the workload-supported method. Never mount one
   ReadWriteOnce EBS volume read-write from two pods simultaneously.
5. Validate file count/checksum and workload-specific invariants on the new
   PVC.
6. During an approved maintenance window, stop the writer, perform the final
   synchronization, switch the workload manifest to the new claim, and start
   the workload.
7. Verify health, dashboards/indexes/metrics as applicable, EBS encryption, the
   `Mandate20Backup=hourly` tag, and a completed hourly recovery point.
8. Keep the old PVC/PV and snapshot for the rollback window. Delete them only
   through a separate approved cleanup change.

## Rollback

Stop the writer, restore the workload manifest to the old claim, and restart.
Do not delete either claim until the migration is signed off.

## Safety gates

- Do not use Argo CD `Replace=true` or force-sync a StorageClass/PVC.
- Do not change a StatefulSet `volumeClaimTemplates` field in place.
- Do not migrate multiple stateful workloads in one maintenance window.
- Do not migrate during an unrelated incident or active deployment.
