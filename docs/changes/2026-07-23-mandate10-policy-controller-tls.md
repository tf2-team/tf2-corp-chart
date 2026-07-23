# Mandate 10 policy-controller TLS repair

## Problem

The production policy-controller was assembled from partial handwritten
manifests. The installation did not include the full CRD set or the webhook
certificate lifecycle supplied by the upstream chart. The live validating
webhook consequently had an empty `caBundle`, and the controller continuously
failed to watch the missing `TrustRoot` resource.

## Change

- Install the official Sigstore policy-controller Helm chart pinned to `0.10.5`.
- Manage it through a dedicated Argo CD Application and least-privilege
  AppProject.
- Preserve the existing AWS KMS-backed `ClusterImagePolicy`.
- Preserve the policy-controller IRSA role annotation.
- Start with `failurePolicy: Ignore` while TLS health is verified.

Production namespace opt-in is deliberately excluded from this change. It is
enabled only after the webhook certificate, CA bundle, CRDs, controller health,
and signed-image admission have been verified.
