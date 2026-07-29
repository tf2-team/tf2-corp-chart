# Change: Harden Sigstore Policy Controller Webhook Availability and Argo Recovery

## Summary

Hardened the Sigstore policy-controller webhook in `techx-corp-chart` to resolve admission saturation and health probe failures during high-throughput Argo CD sync operations. The single webhook replica's logging traffic was reaching 1,266 lines/minute under burst load, causing ECR/S3 verification requests to stall, health probes to time out, and kubelet to restart the controller. With `failurePolicy: Fail`, admission requests were correctly blocked. We upgraded the deployment to a 3-replica High Availability topology with `system-cluster-critical` priority, `workload-class: critical` node placement, hard host anti-affinity, multi-AZ preferred zone anti-affinity, scaled CPU/memory requests and limits, a PodDisruptionBudget (`minAvailable: 2`), and Prometheus scraping annotations. Admission enforcement remains strictly fail-closed (`failurePolicy: Fail`).

## Context

During a recent `techx-corp` release sync, admission requests saturated the single policy-controller webhook pod. The controller experienced severe log volume (1,266 lines/min), leading to delayed verification calls against ECR/S3 and timed-out kubelet liveness/readiness probes. With `failurePolicy: Fail`, unhandled admission calls were rejected, preventing application deployment. The system required an HA capacity upgrade managed purely via GitOps, preserving all security policies, IRSA configurations, and CA bundle ownership rules without adopting `failurePolicy: Ignore` or adding arbitrary timeouts.

## Before

* **Topology:** 1 webhook replica (`replicaCount: 1`).
* **Node placement:** Default node selector and no explicit affinity rules.
* **Priority:** Default pod priority.
* **Resources:** Requested CPU `100m`, memory `128Mi`; Limited CPU `200m`, memory `512Mi`.
* **PDB:** Disabled.
* **Metrics Annotations:** Omitted from `valuesObject`.
* **Behavior under load:** Single-replica bottleneck during concurrent image admission checks leading to probe timeouts and restart loops.

## After

* **Topology:** 3 webhook replicas (`replicaCount: 3`).
* **Node placement:** `commonNodeSelector` set to `workload-class: critical`.
* **Priority:** `priorityClass: system-cluster-critical`.
* **Resources:** Requested CPU `250m`, memory `256Mi`; Limited CPU `1`, memory `512Mi`.
* **Affinity:** `podAntiAffinity` with `requiredDuringSchedulingIgnoredDuringExecution` on `kubernetes.io/hostname` (hard separation across nodes) and `preferredDuringSchedulingIgnoredDuringExecution` (weight 100) on `topology.kubernetes.io/zone` (cross-AZ distribution).
* **PDB:** Enabled with `minAvailable: 2`.
* **Metrics Annotations:** `prometheus.io/scrape: "true"`, `prometheus.io/port: "9090"`, `prometheus.io/path: /metrics`.
* **Security & Failure Policy:** `failurePolicy: Fail`, IRSA role, security context, and CA bundle ownership settings completely preserved.

## Technical Design Decisions

* **Fail-Closed Retention:** Maintained `failurePolicy: Fail` to enforce zero-trust container security contracts. Temporary enforcement bypasses (e.g., `failurePolicy: Ignore`) were rejected to avoid admitting unverified artifacts into production.
* **GitOps-Only Recovery:** Managed all HA parameters directly within `supply-chain-application.yaml` `valuesObject` so Argo CD automatically reconciles state without manual `kubectl` or `helm` mutating commands.
* **Strict Anti-Affinity & PDB:** Required hard pod anti-affinity across hostnames to guarantee that a single node failure cannot compromise more than one webhook replica. Set PDB `minAvailable: 2` to preserve quorum during node maintenance or rolling updates.

## Implementation Details

1. Updated `gitops/clusters/prod/supply-chain-application.yaml`:
   - Configured `commonNodeSelector` with `workload-class: critical`.
   - Merged `webhook` settings for `replicaCount: 3`, `priorityClass: system-cluster-critical`, CPU/memory requests (`250m`/`256Mi`) and limits (`1`/`512Mi`), hostname and zone pod anti-affinity, PDB (`minAvailable: 2`), and Prometheus scrape annotations.
   - Retained chart version `0.10.5`, `failurePolicy: Fail`, IRSA annotations, and COSIGN_REPOSITORY environment configuration.
2. Updated `docs/adr/ADR-M10-secure-delivery-kms-cosign.md`:
   - Documented the 3-replica HA architecture, critical node placement, PDB quorum requirements, and GitOps-only recovery posture under accepted design decisions.
3. Added file change records and change trail comments across all modified files.

## Files Changed

**Configuration:**
* `gitops/clusters/prod/supply-chain-application.yaml` — Configured HA valuesObject (3 replicas, critical node selector, system-cluster-critical priority, anti-affinity, PDB, Prometheus metrics annotations).

**Documentation:**
* `docs/adr/ADR-M10-secure-delivery-kms-cosign.md` — Updated ADR-M10 with 3-replica admission HA, critical-node placement, PDB behavior, and GitOps-only recovery principles.
* `docs/changes/2026-07-29-harden-policy-controller-webhook-availability.md` — This change record.

## Dependencies and Cross-Repository Impact

None. This change is fully self-contained within `techx-corp-chart`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Prevents admission timeouts and probe failure restarts during burst image verification calls. |
| **Infrastructure** | Increases requested resources from 1× 100m/128Mi to 3× 250m/256Mi on critical workload nodes. No new AWS resources required. |
| **Deployment** | Reconciled via Argo CD `supply-chain` application without direct mutating helm/kubectl commands. |
| **Performance** | Multi-replica load distribution eliminates log-saturation latency and liveness probe failures. |
| **Security** | Retains strict `failurePolicy: Fail` and zero-trust image admission enforcement. |
| **Reliability** | Multi-node anti-affinity and PDB (`minAvailable: 2`) ensure continuous admission availability. |
| **Cost** | Minimal increment in node capacity allocation for requested pod resources. |
| **Backward compatibility** | Fully backward-compatible; existing signed workloads admit seamlessly. |
| **Observability** | Exposes Prometheus metrics annotations on port 9090 (`/metrics`) across all 3 replicas. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| YAML Syntax & Structure | `yamllint gitops/clusters/prod/supply-chain-application.yaml` | ✅ Pass |
| Git Whitespace Check | `git diff --check` | ✅ Pass |
| Helm Render Verification | `helm template test oci://ghcr.io/sigstore/helm-charts/policy-controller --version 0.10.5` | ✅ Pass |

### Manual Verification

* Inspected extracted `valuesObject` against Helm chart 0.10.5 schema to confirm proper structure for replicaCount, priorityClass, node selectors, anti-affinity, PDB, and resource specs.
* Verified that `failurePolicy: Fail`, IRSA service account role, and CA bundle `ignoreDifferences` remain unchanged.

### Remaining Verification (Post-Merge)

* Monitor Argo CD reconciliation for `supply-chain` application to reach Synced/Healthy.
* Confirm 3 policy-controller-webhook pods become Ready across distinct nodes in at least 2 Availability Zones.
* Confirm `policy-controller-webhook` Service endpoints report 3 ready targets.
* Verify Prometheus scrapes all 3 replicas for `policy_controller_request_count` metrics.
* Retry the failed application sync and verify clean admission without timeout or EOF errors.

## Migration or Deployment Notes

1. Commit and push the branch `fix/policy-controller-webhook-ha` to `techx-corp-chart`.
2. Merge PR to `main` and allow Argo CD (`root-prod` and `supply-chain`) to reconcile automatically.
3. Do not run direct `kubectl apply` or `helm upgrade` commands against the cluster.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Placement constraints prevent 3 replicas from scheduling | Low | Medium | Relax hard host placement to preferred anti-affinity via Git update if node capacity is constrained. |
| Webhook instability under multi-replica operation | Low | High | Revert the Git commit on `techx-corp-chart/main` and allow Argo CD to reconcile back to baseline. |

**Rollback procedure:**

1. Revert the HA commit in Git: `git revert <commit-sha>`.
2. Push the revert commit to `techx-corp-chart/main`.
3. Allow Argo CD to reconcile the previous deployment state.
<!-- Change trail: @hungxqt - 2026-07-29 - Record webhook availability hardening and Argo recovery design. -->
