# Mandate 17 resilience and containment evidence

## Scope and verdict

This record covers the mentor requirements in
`MANDATE-17-resilience-and-containment.md`: graceful optional-dependency
failure, whole-AZ loss, network blast-radius containment, and least-privilege
workload identity.

The implementation and live gates are complete. The accepted reliability runs
used production chart revision `4899e05`; no SLO was lowered, no broad network
allowlist was added, and flagd was excluded from fault mutation.

## Revisions

| Component | Verified revision |
|---|---|
| Platform `origin/main` | `e3f6f5142511a58ea3b51e3ab864f530dc3a71ff` |
| Chart and Argo production | `4899e054f43d3af3795f4aced5b41f0f7861f0d4` |
| Infra `origin/main` | `5e07b2cfe1ec54a00638dd45e96638abd59e8f74` |
| Final AZ harness | `0d85f980001507ec2dfb18fd95c45049d9f0e377` |
| Frontend runtime digest | `sha256:3249a2f8275a05f52ffea476c2fa559e097a5acd1e6036d2640addb6079f9ed2` |

Platform PR #54 supplied the runtime fallback. Platform PR #59 added automated
contract tests only, so production correctly stayed on the already verified
runtime digest. Chart PRs #178/#187 supplied identity, topology and containment;
#226 restricted Kubernetes API access to the inventoried consumers; #253–#256
hardened Linkerd runtime and the fault harness; #259 fixed only the proven
Linkerd init redirect on managed Valkey TCP 6379; #260 added reversible
provisioning fencing.

## Local and static verification

The final branch passed:

- Helm lint with production values;
- rendered disabled, ingress-only, full-egress, egress-proxy and attacker
  NetworkPolicy contracts;
- chaos-script mutation/cleanup contracts;
- Directive #3 public/private exposure checks;
- live identity/token/RBAC inventory for 21 first-party workloads;
- CoreDNS readiness and AZ `-WhatIf`.

No application or infrastructure remediation was introduced for the final
evidence run. The only final harness change waits for actual target-Pod
evacuation before opening the AZ acceptance window.

## Identity, RBAC and IRSA

- 21/21 first-party workloads use dedicated ServiceAccounts.
- Default Kubernetes token automount is disabled.
- Dangerous `auth can-i` checks return `no`; no wildcard application binding
  exists.
- checkout, product-reviews, and shopping-copilot use scoped IRSA roles and
  projected STS tokens without a default Kubernetes token.
- The attacker has no Kubernetes token and cannot read Secrets.

The production inventory Job passed with `violationCount=0`. Old failed Job
history was removed only after consecutive successful scans; the final
recovery snapshot contains zero failed Jobs.

## Network containment

Production runs with:

```yaml
networkPolicy:
  enabled: true
  enforceEgress: true
egressProxy:
  enabled: true
```

The positive matrix preserves the public storefront, private operations,
observability, flagd, DNS, declared service dependencies, and only the seven
inventoried Kubernetes API consumers. The attacker matrix passed: DNS lookup
works, while service lateral movement, Argo, Kubernetes API, egress proxy,
Internet, RDS, MSK and Valkey access are denied. Attacker resources are removed
in `finally`.

Static rollback proof remains:

```text
true/true -> true/false -> false/false
```

A live C2 rollback was not repeated because C2 was healthy and the mentor
requirement is containment evidence, not an unnecessary production rollback.

## Dependency fault

Authoritative artifacts:
`reliability-20260724-150008/dependency-ad`.

The `ad` Deployment kept desired replicas at two while the deletion loop held
its EndpointSlice at zero Ready endpoints for the fault window. Six of six
cache-busted `/api/data` probes returned:

- HTTP 200;
- body `[]`;
- `X-TechX-Degraded-Dependencies: ad`;
- structured `optional_dependency_fallback` log evidence.

k6 completed 600 iterations: browse/cart/checkout 100%, browse p95 525.46 ms,
zero failed requests and zero dropped iterations. Cleanup stopped the deletion
loop, restored `ad` 2/2 and two Ready endpoints, and returned Argo to Healthy.

`ad` was selected because it is optional on the browse data path, has an
explicit fallback contract, and is a fixed two-replica Deployment without HPA
ownership conflict. Recommendation was retained as a second documented
optional dependency, not mutated concurrently.

## Whole-AZ loss

Authoritative artifacts:
`reliability-20260724-190910`.

### Entry gate and capacity

Locust was explicitly stopped at zero users. The five-minute baseline on
`4899e05` completed 601 iterations with browse/cart/checkout 100%, browse p95
316.42 ms, and zero dropped iterations. The seven-node set did not change.

CoreDNS was 2/2 across two nodes/two AZs. All Argo applications were
Synced/Healthy, all Deployments Available, and every node Ready/uncordoned.
The surviving `us-east-1b` zone had approximately 3420m free requested CPU and
10.25 GiB free requested memory versus 1390m CPU and 1.63 GiB requested by the
13 selected Pods. `requiresScaleOut` was false.

### Fault and SLO

The approved command used `-CapacityApproved -FenceProvisioning -Execute`.
Both stateless NodePools were atomically fenced to `us-east-1b`. The harness
cordoned two `us-east-1a` nodes and evacuated all 13 selected first-party
Deployment Pods in 26.462 seconds before starting the 300-second acceptance
window. No new node entered the failed AZ.

The 10-minute external k6 run completed:

| Signal | Result |
|---|---:|
| Iterations | 1200 |
| Browse | 100% |
| Cart | 100% |
| Checkout | 1199/1200 (99.9167%) |
| Browse p95 | 311.46 ms |
| Dropped iterations | 0 |

DNS and flagd stayed Ready. One checkout did not meet the HTTP-200-with-order
check, remaining within the required >=99% SLO. This k6 version persisted only
aggregate output, so it cannot prove the exact response timestamp/body.
Prometheus showed no non-200 `/api/checkout` handler increment in the fault
interval. Evidence therefore supports only a pre-handler transient during Pod
evacuation; it does not support assigning an application/payment root cause.

### Rollback and recovery

Cleanup restored exact zone requirements on both NodePools. Node
`ip-10-0-16-62` was uncordoned; `ip-10-0-29-227` had already been replaced and
was recorded as `NotFound/replaced`. Every current node was subsequently
Ready/uncordoned.

The independent five-minute recovery run completed 600 iterations with
browse/cart/checkout 100%, browse p95 308.61 ms, zero failed requests and zero
dropped iterations. The final snapshot at `19:42:56 +07` shows all Argo
applications Synced/Healthy, every Deployment Available/updated, both
NodePools restored to two AZs, CoreDNS 2/2, flagd 1/1, and zero failed Jobs.

## Invalid runs retained for audit

- `reliability-20260724-182851`: baseline passed, but the harness stopped
  before opening the fault window because asynchronous Pod deletion had not
  completed. Cleanup passed.
- `reliability-20260724-185120`: retained for post-baseline node-convergence
  diagnosis.
- `reliability-20260724-190043`: aborted before fault injection when the node
  set changed.

These runs demonstrate that the gate stopped on invalid conditions; they are
not counted as reliability proof.

## Reproduction and safety

The exact one-command dependency, AZ and attacker reproductions are indexed in
[`README.md`](README.md). Mutating scripts require an explicit `-Execute`;
AZ loss additionally requires `-CapacityApproved` and
`-FenceProvisioning`. Cleanup is in `finally`, dependency and AZ faults must
never overlap, and the entry baseline must be rerun if revision, load owner or
node state changes.

No evidence artifact contains a Secret, token, authorization header, webhook
URL, or customer payload.
