# ADR SEC-07: Production runtime hardening with Gatekeeper

- Status: Accepted for staged rollout
- Date: 2026-07-15
- Owners: Platform Security and Platform Engineering
- Approver signature: Pending production audit and mentor acceptance
- Cutover commit: Pending

## Context

The production render contained eight unpinned BusyBox init-container images,
missing init-container resources, and Grafana's root `init-chown-data` container.
Static chart cleanup removes those known violations, but future manifests also
need an admission guardrail.

## Decision

Install the pinned upstream Gatekeeper chart `3.23.0` from the dedicated
`gatekeeper-chart` wrapper in this repository. Argo CD owns both the Gatekeeper
Helm release and three policies; AWS Terraform is not part of this decision:

- `K8sContainerHardening`: effective `runAsNonRoot=true`, no effective
  `runAsUser=0`, capability drop `ALL`, and no added Linux capabilities for
  containers, init containers, and ephemeral containers.
- `K8sAllowedImageTags`: fixed tags or valid SHA-256 digests; no missing tag or
  case-insensitive `latest`.
- `K8sRequiredResources`: CPU/memory requests and limits for containers and init
  containers. Kubernetes does not support resources on ephemeral containers.

Policies cover Pod, Deployment, StatefulSet, DaemonSet, ReplicaSet, Job,
CronJob, and ReplicationController. Only `kube-system`, `kube-public`,
`kube-node-lease`, and `gatekeeper-system` are excluded. Any future exception
must record owner, reason, expiry, and Platform Security approval.

The controller Application installs the chart into `gatekeeper-system`. The
policy Application remains separate because Gatekeeper must first install its
CRDs and generate the constraint CRDs before Constraints can be admitted. The
webhook is fail-closed and runs with two controller replicas, a PDB, and the
existing Critical MNG. Mutation, external data, generated-resource expansion,
and CRD upgrade hooks are disabled. This adds no separately billed AWS service
and requires no change in `tf2-corp-infra` beyond Argo bootstrap docs.

**Application ownership:** A root app-of-apps Application (`root-prod` from
`gitops/bootstrap/prod/`) reconciles child Application/AppProject CRs under
`gitops/clusters/prod/` (including Gatekeeper). Operators bootstrap the root once;
they do not hand-apply Gatekeeper Application manifests in steady state. The
policy Application remains **manual sync** until deny cutover.

## Rollout and rollback

1. Deploy chart cleanup and verify workload health, storefront access boundaries,
   and flagd behavior.
2. Ensure root-prod is applied; wait for the Gatekeeper controller Application
   (`gatekeeper` / `gatekeeper-chart`) until both controller and audit Deployments
   are available.
3. Render the reviewed chart revision to a temporary output, change only that
   output to `enforcementAction: dryrun`, and apply it before syncing the
   Argo CD policy Application.
4. Observe at least two audit cycles and record zero violations below.
5. Enable automated sync on the policy Application (or run a one-time
   `argocd app sync gatekeeper-policy`) from the same reviewed chart revision.
   Its source of truth keeps all three constraints at final state `deny`.
6. Run the mentor rejection demo and sign this ADR.

For a false positive, revert constraints to `dryrun` through Git and Argo CD,
add a regression fixture, then repeat audit. If the fail-closed webhook is
unavailable, restore its controller first; fail-open is break-glass only and
requires approval plus an audit trail.

## Evidence

| Evidence | Result | Commit/time |
|---|---|---|
| Production Helm render compliance inventory | Pending deploy | Pending |
| Three constraints, two audit cycles, zero violations | Pending | Pending |
| Constraints switched to `deny` | Pending | Pending |
| Mentor invalid-manifest rejection | Pending | Pending |
| Storefront/private ops/flagd regression checks | Pending | Pending |

## Signatures

| Role | Name | Signature/date |
|---|---|---|
| Platform Engineering | @hungxqt | Pending |
| Platform Security |  | Pending |
| Service owner representative |  | Pending |

<!-- Change trail: @hungxqt - 2026-07-16 - Document root app-of-apps ownership for Gatekeeper apps. -->
