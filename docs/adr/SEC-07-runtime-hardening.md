# ADR SEC-07: Native Kubernetes runtime-hardening admission

- Status: Phase 1 verified; production audit cutover pending
- Date: 2026-07-18
- Owners: Platform Security and Platform Engineering
- Target cluster: `techx-tf2-prod`, Kubernetes `v1.36.2`
- Cutover commit: Pending

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

The production Argo Application initially points to the audit overlay with
`[Warn, Audit]`. A reviewed PR changes only the Application path to the enforce
overlay with `[Deny]` after inventory and regression gates pass. System namespaces
and the temporary `gatekeeper-system` migration namespace are excluded. The
Gatekeeper exclusion must be removed after retirement; any later exception needs
an owner, reason, expiry, and Platform Security approval.

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
| EKS 1.36 server-side dry-run of three policies | PASS | 2026-07-18 |
| Full live inventory | PASS - 135 objects, 191 containers, zero violations | 2026-07-18 |
| Native fixture suite on disposable cluster | PASS - valid Pod/Deployment/Job/CronJob admitted; invalid root, UID 0, capability, image, resources, CREATE and UPDATE denied | Minikube v1.35.1; 2026-07-18 |
| Audit overlay behavior on disposable cluster | PASS - invalid root admitted with native VAP warning after binding cache propagation | Minikube v1.35.1; 2026-07-18 |
| VAP audit conditions and warning observation | Pending Phase 2 | Pending |
| VAP deny CREATE/UPDATE mentor demo | Pending Phase 3 | Pending |
| Gatekeeper retirement inventory | Pending Phase 4 | Pending |
| Storefront/private ops/flagd/SLO regression | Pending each production phase | Pending |

Historical Gatekeeper screenshots remain under `docs/adr/evidence/sec-07/` as
pre-migration evidence. Final acceptance must capture VAP denial output naming
the native policy and binding, not `validation.gatekeeper.sh`.

## Signatures

| Role | Name | Signature/date |
|---|---|---|
| Tech Lead | Trần Quốc Hùng | Pending migration acceptance |
| Platform Security |  | Pending |
| Service owner representative |  | Pending |
