# Phase 3 native VAP production proof

- Date: 2026-07-19
- Cluster: `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod`
- Git revision: `7e7fbb41af2881a89d38916361e0b7c6db1b1061`
- Change window: Gatekeeper Constraints were temporarily patched from `deny`
  to `dryrun`, then restored to `deny` after the proof.

## Admission results

| Fixture | Operation | Result | Denial source |
|---|---|---|---|
| `invalid-root.yaml` | CREATE Pod | Denied | `runtime-hardening-pod.techx.io` |
| `invalid-uid-zero.yaml` | CREATE Pod | Denied | `runtime-hardening-pod.techx.io` |
| `invalid-capability.yaml` | CREATE Pod | Denied | `runtime-hardening-pod.techx.io` |
| `invalid-latest-deployment.yaml` | CREATE Deployment | Denied | `runtime-hardening-pod-template.techx.io` |
| `invalid-resources-job.yaml` | CREATE Job | Denied | `runtime-hardening-pod-template.techx.io` |
| `valid-pod.yaml` | CREATE Pod | Admitted | n/a |
| `update-latest-pod.yaml` | UPDATE Pod | Denied | `runtime-hardening-pod.techx.io` |

Every rejected request named the native `ValidatingAdmissionPolicy` and its
binding. No rejection named `validation.gatekeeper.sh`.

## Restoration and post-checks

- The temporary valid Pod was deleted; no `vap-valid-*` or `vap-invalid-*`
  fixture objects remain.
- All three Gatekeeper Constraints were restored to `deny` and reported zero
  violations.
- All three native VAP bindings remained `[Deny]`.
- All three VAP generations were observed with no expression warnings.
- Static render verification passed.
- Non-system inventory passed: 175 workload objects and 239 containers checked,
  with zero violations.
- Storefront returned HTTP 200. `/grafana/`, `/jaeger/`, `/argocd/`, and
  `/feature` each returned HTTP 403.
- The flagd Pod remained Running with both containers ready and zero restarts.

## Pre-existing health blocker

`techx-corp` remained `Synced/Degraded` before and after this proof because the
Mem0 `fetch-mem0-fastembed` init container received `HeadObject 403` while
fetching its S3 model. The admission proof did not create this failure. Formal
SLO acceptance and Gatekeeper retirement remain blocked until application
health is clean.
