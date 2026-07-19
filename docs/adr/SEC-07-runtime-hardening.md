# ADR SEC-07: Native Kubernetes runtime-hardening admission

- Status: Phase 1-2 complete; Phase 3 admission proof passed; application/SLO acceptance blocked; cluster-wide system audit pending
- Date: 2026-07-19
- Owners: Platform Security and Platform Engineering
- Target cluster: `techx-tf2-prod`, Kubernetes `v1.36.2`
- Cutover commit: `7605191c5367985fa091580c84a4c076fcd6462c`

## Context

The production chart has already remediated root containers, floating images,
and missing CPU/memory requests and limits. Gatekeeper 3.23.0 currently prevents
those violations from returning, but it adds controller and audit Deployments,
a webhook Service, certificates, CRDs, and worker resource consumption. MANDATE-05
requires admission policy without introducing another in-cluster policy service.

The target EKS API server provides stable
`ValidatingAdmissionPolicy`/`ValidatingAdmissionPolicyBinding` APIs. Native CEL
policy therefore preserves automatic admission enforcement without a controller,
Service, certificate, CRD, network hop, or Terraform/AWS resource.

## Decision

Migrate the three runtime-hardening rules to native VAP/CEL:

1. Container hardening requires effective `runAsNonRoot=true`, forbids effective
   UID 0, requires capability drop `ALL`, and rejects added capabilities.
2. Image pinning rejects missing tags, case-insensitive `latest`, and malformed
   digests; fixed tags and valid SHA-256 digests are accepted.
3. Resource requirements enforce CPU/memory requests and limits for containers
   and init containers. Ephemeral containers are excluded from this rule because
   Kubernetes does not support resources on them.

Three policies follow the three native PodSpec shapes: Pod,
controller/Job template, and CronJob template. They cover CREATE and UPDATE for
Pod, Deployment, StatefulSet, DaemonSet, ReplicaSet, ReplicationController, Job,
and CronJob. Security and image checks include containers, init containers, and
ephemeral containers when present.

The production Argo Application currently points to the migration enforce
overlay with three `[Deny]` bindings. That overlay temporarily excludes
`kube-system`, `kube-public`, `kube-node-lease`, and `gatekeeper-system`. The
audit overlay is cluster-wide and the final `enforce-clusterwide` overlay has no
namespace selector. Promotion to the final overlay requires a literal
full-cluster inventory gate. Any necessary exception must target a specific
workload/service account and record owner, reason, expiry, and Platform Security
approval; a namespace-wide final exception is not accepted.

## Migration safety

1. Keep Gatekeeper at `deny` while VAP source, tests, and audit binding are added.
2. Deploy VAP `[Warn, Audit]`; require observed generations with zero type-check
   warnings, zero live inventory violations, and no
   storefront/private-route/flagd/SLO regression.
3. Promote VAP to `[Deny]`, then temporarily set Gatekeeper Constraints to
   `dryrun`. Prove invalid CREATE and UPDATE requests are denied by VAP and a
   valid manifest is admitted.
4. Remove the Gatekeeper webhook before its Service/controller, prove VAP still
   denies, then remove Gatekeeper policy resources, workloads, CRDs, and namespace.
5. Remediate or explicitly approve system workload exceptions, require a clean
   full-cluster inventory, then promote to `enforce-clusterwide`.

There must never be a point where both VAP and Gatekeeper are non-enforcing.
Existing workloads are not killed by a binding action change; rollout remains
blocked whenever application health or SLO evidence is not clean.

## Rollback

- Before Gatekeeper retirement, revert the VAP Application to the audit overlay
  and restore all Gatekeeper Constraints to `deny`.
- After retirement, revert the binding from `[Deny]` to `[Warn, Audit]`, add a
  regression fixture, correct CEL, and repeat the cutover gates.
- Reinstalling Gatekeeper is not the default response to a CEL false positive;
  it requires a native API platform failure and Platform Security approval.
- Never disable flagd or alter public/private routing to work around admission.

## Evidence

| Evidence | Result | Commit/time |
|---|---|---|
| Legacy Gatekeeper baseline | PASS - three deny constraints, zero violations | 2026-07-17 |
| VAP base/audit/enforce render | PASS locally | 2026-07-18 |
| VAP enforce-clusterwide render | PASS locally - three Deny bindings, no namespace selector | 2026-07-18 |
| EKS 1.36 server-side dry-run of three policies | PASS | 2026-07-18 |
| Non-system live inventory | PASS - 171 objects, 231 containers, zero violations | 2026-07-18 |
| Literal full-cluster inventory | FAIL - 264 raw violations across 39 violating objects; 53 root-owner remediation groups, 26 violating running Pods, zero runtime-drift groups; 218 workload objects checked in the latest run (checked count varies during rollouts) | 2026-07-18 |
| Native fixture suite on disposable cluster | PASS - valid Pod/Deployment/Job/CronJob admitted; invalid root, UID 0, capability, image, resources, CREATE and UPDATE denied | Minikube v1.35.1; 2026-07-18 |
| Audit overlay behavior on disposable cluster | PASS - invalid root admitted with native VAP warning after binding cache propagation | Minikube v1.35.1; 2026-07-18 |
| VAP audit conditions and warning observation | PASS - Phase 2 completed; audit bindings retired after enforce promotion | 2026-07-18 |
| Native VAP deny CREATE/UPDATE production proof | PASS - with all three Gatekeeper Constraints temporarily at `dryrun`, VAP denied root, UID 0, added capability, `latest`, missing resources, and invalid UPDATE fixtures; a valid Pod was admitted; Gatekeeper was then restored to `deny` ([evidence](evidence/sec-07/05-native-vap-phase3-proof.md)) | 2026-07-19 |
| Phase 3 post-proof non-system inventory | PASS - 175 workload objects and 239 containers checked; zero violations | 2026-07-19 |
| Phase 3 post-proof policy state | PASS - three VAP bindings remain `[Deny]`; three Gatekeeper Constraints restored to `deny` with zero violations; no fixture objects remain | 2026-07-19 |
| Phase 3 application/SLO gate | BLOCKED - pre-existing Mem0 init failure (`HeadObject 403` while fetching the S3 model) keeps `techx-corp` Degraded; other Argo Applications are Synced/Healthy | 2026-07-19 |
| Gatekeeper retirement inventory | Pending Phase 4 | Pending |
| Phase 3 storefront/private ops/flagd smoke | PASS - storefront 200; Grafana, Jaeger, Argo CD, and feature operations routes 403; flagd Running with zero restarts | 2026-07-19 |
| Phase 3 formal SLO regression | BLOCKED - collect k6/Grafana p95 after the pre-existing Mem0 health failure is resolved | Pending |
| Phase 3B system resource remediation | READY FOR REVIEW - Terraform/EKS add-on and Helm configuration prepared for VPC CNI, CoreDNS, kube-proxy, EBS CSI, Karpenter, and AWS Load Balancer Controller | 2026-07-19 |
| Phase 3B exact system exceptions | PENDING APPROVAL - six workload/service-account candidates documented; no namespace-wide exception and no candidate is active ([candidates](evidence/sec-07/06-system-exception-candidates.md)) | Pending Platform Security approval |

Historical Gatekeeper screenshots remain under `docs/adr/evidence/sec-07/` as
pre-migration evidence. Final acceptance must capture VAP denial output naming
the native policy and binding, not `validation.gatekeeper.sh`.

## Signatures

| Role | Name | Signature/date |
|---|---|---|
| Tech Lead | Trần Quốc Hùng | Pending migration acceptance |
| Platform Security |  | Pending |
| Service owner representative |  | Pending |
