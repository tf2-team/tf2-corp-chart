# Phase 4 Gatekeeper retirement proof

- Date: 2026-07-19
- Cluster: `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod`
- Retirement gate revision: `77c6352`
- Operator backup: `D:\tf2-corp-infra\backups\mandate05-gatekeeper-20260719-104901`

## Preconditions

- `gatekeeper` and `gatekeeper-policy` were manual-sync Applications.
- All production Applications were Synced and Healthy before retirement.
- All three native VAP generations were observed with zero non-null type-check
  warnings.
- All three native bindings were `[Deny]`.
- All three Gatekeeper constraints were `deny` with zero violations.
- The restricted local backup contains Applications, webhook configuration,
  namespace resources including the TLS Secret, cluster RBAC, CRDs, custom
  resources, and SHA-256 checksums. It must not be committed.

## Retirement sequence

1. Deleted `gatekeeper-validating-webhook-configuration` first.
2. Submitted an invalid Pod with server-side dry-run. Kubernetes denied it via
   `runtime-hardening-pod.techx.io` and
   `runtime-hardening-pod-enforce.techx.io`.
3. Cascade-deleted `gatekeeper-policy`, then `gatekeeper`, through Argo CD.
4. Confirmed no Gatekeeper webhook, workload, Service, PDB, Secret, cluster
   RBAC, ConstraintTemplate, or Constraint remained.
5. Confirmed there were no Gatekeeper custom resources, then deleted the 17
   remaining generic Gatekeeper CRDs.
6. Deleted `gatekeeper-system` and confirmed it no longer exists.
7. Re-ran the invalid Pod server-side dry-run and confirmed native VAP still
   denied the request.

## Regression checks

- All application Pods were Running and Ready with zero container restarts.
- flagd remained Running, both containers Ready, with zero restarts.
- Storefront `/`: HTTP 200.
- `/grafana/`, `/jaeger/`, `/argocd/`, and `/feature`: HTTP 403.
- `root-prod`, `runtime-hardening`, `techx-corp`, and
  `techx-corp-secrets` remained Synced and Healthy.
- The two manual Gatekeeper child Applications were expectedly recreated by
  `root-prod` as OutOfSync/Missing until their source manifests are removed.

## Remaining gate

Merge the Gatekeeper source cleanup, remove the two recreated child
Applications and obsolete AppProject, confirm Argo health, run literal
full-cluster inventory, and only then promote `runtime-hardening` to
`overlays/enforce-clusterwide`.
