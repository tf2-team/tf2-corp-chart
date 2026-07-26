# Change: Encrypted gp3 StorageClass and PVC storage class defaults

## Summary

Adds cluster StorageClass `gp3-encrypted` (EBS CSI, `encrypted: "true"`, gp3) and switches chart default / Prometheus / Grafana persistence to that class so new claims provision encrypted volumes. Existing live PVCs still need Phase 4 snapshot→encrypt→rebind (recorded with before/after).

## Context

Chart used `gp2` without encryption parameters. Live prod PVCs (prometheus 8 Gi, grafana 1 Gi, opensearch 10 Gi) are unencrypted. Infra change enables node-level encryption and orphan cleanup; this chart change covers dynamic PVC path and documents PVC migration process evidence.

Related: `techx-corp-infra/docs/changes/2026-07-22-ebs-encryption-and-orphan-cleanup.md`.

## Before

**Code:**

* `default.storageClassName: gp2`
* `prometheus.server.persistentVolume.storageClass: gp2`
* `grafana.persistence.storageClassName: gp2`
* No chart-managed encrypted StorageClass.

**Live PVC volumes (baseline from infra inventory `2026-07-22T09:48:26Z`):**

| VolumeId | PVC | NS | Size | Encrypted | State |
|---|---|---|---|---|---|
| `vol-05b854adac88d324e` | prometheus | techx-corp-prod | 8 | false | in-use |
| `vol-04b630daaf7625c77` | grafana | techx-corp-prod | 1 | false | in-use |
| `vol-085a38efdb1a24c2a` | opensearch-data-opensearch-0 | techx-corp-prod | 10 | false | in-use |

**Note:** Changing SC name in values does **not** re-encrypt existing PVCs until Phase 4 rebind.

## After

### Code (this commit)

* Template `templates/storageclass-gp3-encrypted.yaml` — provisioner `ebs.csi.aws.com`, `type=gp3`, `encrypted=true`, `WaitForFirstConsumer`, expansion enabled.
* Values default + Prometheus + Grafana → `gp3-encrypted`.
* StatefulSet VCT components using `{{ .defaultValues.storageClassName }}` (kafka, postgresql, valkey-cart, opensearch) inherit `gp3-encrypted` for **new** claims.

### Ops phases (fill as executed)

#### Phase 3 — GitOps sync SC

| Field | Value |
|---|---|
| Before | No `gp3-encrypted` SC (only in-tree `gp2`) |
| Chart on main | Yes (`62ecbc3` via PR #220 / merge on `main`) |
| Sync failure | Argo: `resource storage.k8s.io:StorageClass is not permitted in project techx-corp` |
| Fix | Add `storage.k8s.io/StorageClass` to `gitops/clusters/prod/appproject.yaml` clusterResourceWhitelist |
| After Argo | SC `gp3-encrypted` present (`ebs.csi.aws.com`, `encrypted: "true"`) after AppProject whitelist push `774a607` |
| Expected met | Yes for SC; PVCs migrated in Phase 4 |

#### Phase 4a — Grafana

| Field | Value |
|---|---|
| Before | `vol-04b630daaf7625c77` Encrypted=false, AZ us-east-1b |
| Map | old `vol-04b630daaf7625c77` → snap `snap-070319393f698d4df` → enc_snap `snap-0603408edb99ef3ca` → new `vol-0807f3ccbbfbf3bec` |
| After | PVC Bound `gp3-encrypted` / `pv-enc-grafana`; Encrypted=true; pod **2/2 Running** after zone nodeAffinity fix |

#### Phase 4b — Prometheus

| Field | Value |
|---|---|
| Before | `vol-05b854adac88d324e` Encrypted=false, AZ us-east-1a |
| Map | old `vol-05b854adac88d324e` → snap `snap-0db153734790714a9` → enc_snap `snap-03acbaf8ed8e8968c` → new `vol-066f84fa4ab9bd406` |
| After | PVC Bound `gp3-encrypted` / `pv-enc-prometheus`; Encrypted=true; pod **1/1 Running** |

#### Phase 4c — OpenSearch

| Field | Value |
|---|---|
| Before | `vol-085a38efdb1a24c2a` Encrypted=false, AZ us-east-1b |
| Map | old `vol-085a38efdb1a24c2a` → snap `snap-0fa860a29f2ef73f0` → enc_snap `snap-076b6a516ff8d2757` → new `vol-03755abdce1928b77` |
| After | PVC Bound `gp3-encrypted` / `pv-enc-opensearch`; Encrypted=true; STS recreated by Argo; pod Running (startup probe slow — security/JVM cold start) |

**Ops notes:** Argo auto-sync paused during rebind; static PVs required `topology.kubernetes.io/zone` nodeAffinity to avoid AZ mismatch; old unencrypted volumes deleted after cutover.

## Technical Design Decisions

* **New SC name `gp3-encrypted`** rather than mutating in-tree `gp2` — avoids surprising existing claims; explicit encryption intent.
* **Not default-class annotation** initially — reduce blast radius; chart sets SC name explicitly.
* **gp3** preferred over gp2 for new volumes (cost/perf); aligns with infra COST notes.
* **Static PV rebind** for Phase 4 to preserve data via encrypted snapshot copy (operator-run).

## Implementation Details

1. Added StorageClass manifest to chart templates (cluster-scoped object shipped with app release).
2. Updated three values storage class fields to `gp3-encrypted`.
3. Phase 4 procedure (per PVC; CMD/kubectl; **approval required**):

```cmd
REM 1) Snapshot + encrypt copy + create volume (same AZ)
aws ec2 create-snapshot --region us-east-1 --volume-id vol-OLD ...
aws ec2 copy-snapshot --region us-east-1 --source-region us-east-1 --source-snapshot-id snap-SRC --encrypted --kms-key-id alias/aws/ebs ...
aws ec2 create-volume --region us-east-1 --availability-zone us-east-1X --snapshot-id snap-ENC --volume-type gp3 --encrypted ...

REM 2) Scale down consumer; PV reclaim Retain; rebind PVC to static PV for vol-NEW
REM 3) Scale up; verify Encrypted=true; delete old volume after soak
```

Order: Grafana → Prometheus → OpenSearch.

## Files Changed

**Templates:**

* `templates/storageclass-gp3-encrypted.yaml` — encrypted gp3 SC for EBS CSI.

**Configuration:**

* `values.yaml` — `default.storageClassName`, Prometheus `storageClass`, Grafana `storageClassName` → `gp3-encrypted`.

**Documentation:**

* `docs/changes/2026-07-22-encrypted-storageclass-and-pvc-sc.md` — this record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-infra/docs/changes/2026-07-22-ebs-encryption-and-orphan-cleanup.md`.
* Requires `aws-ebs-csi-driver` addon (already on cluster via infra).
* Prefer account default encryption enabled (infra Phase 2.1) before/at PVC migrate.
* Argo CD auto-sync applies SC and values after merge; **do not** helm-upgrade outside GitOps.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No immediate data change until Phase 4; new PVCs encrypt |
| **Deployment** | Argo sync; Phase 4 needs maintenance windows for obs stack |
| **Security** | New dynamic volumes encrypted |
| **Reliability** | Phase 4 rebind risk mitigated by snaps + Retain |
| **Backward compatibility** | Existing PVC objects unchanged until rebind; SC name change is forward-looking |
| **Observability** | Brief Grafana/Prometheus/OpenSearch downtime during Phase 4 |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Pass (icon info only) |
| Template SC | `helm template` includes `kind: StorageClass` name `gp3-encrypted` | Pass |

### Manual Verification

* Values grep shows no remaining default `gp2` storage class for app persistence (hard-coded gp2 removed).
* Phase 3/4 after-state tables filled during ops.

### Remaining Verification (Post-Merge)

* Argo sync; `kubectl get sc gp3-encrypted -o yaml`.
* Phase 4 migrations; confirm three live volumes Encrypted=true.
* Smoke: Grafana UI, Prometheus targets, OpenSearch health.

## Migration or Deployment Notes

1. Merge chart PR; wait Argo Healthy for SC.
2. Do **not** delete live PVCs until Phase 4 procedure with encrypted volume ready.
3. After each PVC migrate, record map row and health in this doc.
4. Coordinate with infra End state table.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| SC missing → Pending PVC | Medium | Medium | Ensure Argo synced SC before new claims |
| Rebind data loss | Medium | High | Encrypted snap retained; old vol until soak |
| Subchart ignores storageClass | Low | Medium | Verify rendered Prometheus/Grafana manifests |

**Rollback procedure:**

* Revert values to `gp2` and remove SC template via Git (Argo).
* Phase 4 failure: reattach old volume via static PV from Retain volume/snap.

<!-- Change trail: @hungxqt - 2026-07-22 - Encrypted StorageClass and SC defaults with PVC migrate process log. -->
