# Mandate 10 production policy migration

## Incident

Chart promotion PR #193 updated the immutable digests for `email`, `llm`, and
`opensearch`. Argo CD could not patch `email` or `llm` because the existing
cluster-wide runtime-hardening binding denied updates to legacy Deployments
that do not yet define complete CPU and memory requests and limits.

## Temporary migration control

- Retain `Deny` for namespaces other than `techx-corp-prod`.
- Apply `Warn` and `Audit` to `techx-corp-prod` so violations remain visible
  while the production workloads are remediated.
- Do not weaken the underlying policies or their `failurePolicy: Fail` setting.

This exception must be removed after every enabled production workload passes
the runtime-hardening inventory and the namespace is proven safe under a
server-side dry-run.

## Rollback

Restore the runtime-hardening Application path to
`gitops/runtime-hardening/overlays/enforce-clusterwide` after production is
compliant. If this change causes unexpected admission behavior, revert this PR;
the original cluster-wide deny bindings will be restored by Argo CD.
