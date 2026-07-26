# Mandate 17 evidence index

## Completion status

All mentor outcomes have authoritative implementation and live evidence:

| Outcome | Result | Evidence |
|---|---|---|
| Optional dependency fault and recovery | PASS | [`reliability-20260724-150008/dependency-ad`](reliability-20260724-150008/dependency-ad) |
| Whole-AZ loss, rollback, and recovery | PASS | [`reliability-20260724-190910`](reliability-20260724-190910) |
| Network containment and attacker matrix | PASS | [`attacker-20260723-103854`](attacker-20260723-103854) |
| Dedicated identity, token-off, RBAC and IRSA | PASS | [`resilience.md`](resilience.md#identity-rbac-and-irsa) |

The consolidated narrative, revisions, results, rollback proof, and limitations
are in [`resilience.md`](resilience.md).

## Authoritative revisions

| Component | Revision |
|---|---|
| Platform `origin/main` | `e3f6f5142511a58ea3b51e3ab864f530dc3a71ff` |
| Chart/Argo production revision | `4899e054f43d3af3795f4aced5b41f0f7861f0d4` |
| Infra `origin/main` | `5e07b2cfe1ec54a00638dd45e96638abd59e8f74` |
| AZ harness used by the final run | `0d85f980001507ec2dfb18fd95c45049d9f0e377` |

Important implementation history:

- Platform PR #54: runtime optional-dependency timeout/fallback.
- Platform PR #59: automated contract verification; no production image
  promotion was required for test-only changes.
- Chart PR #178: identity, topology and initial chaos tooling.
- Chart PR #187: NetworkPolicy production activation.
- Chart PR #226: least-privilege Kubernetes API consumer allowlist.
- Chart PRs #253–#256: Linkerd runtime and chaos-harness hardening.
- Chart PR #259: scoped Linkerd init bypass for managed Valkey TCP 6379.
- Chart PR #260: reversible NodePool zone fencing for the AZ test.

## Live reliability results

| Window | Iterations | Browse | Cart | Checkout | Browse p95 | Dropped |
|---|---:|---:|---:|---:|---:|---:|
| Entry baseline, `4899e05` | 601 | 100% | 100% | 100% | 316.42 ms | 0 |
| Ad unavailable | 600 | 100% | 100% | 100% | 525.46 ms | 0 |
| `us-east-1a` unavailable | 1200 | 100% | 100% | 99.9167% | 311.46 ms | 0 |
| Post-AZ recovery | 600 | 100% | 100% | 100% | 308.61 ms | 0 |

During the ad fault, desired replicas remained two, ready endpoints reached
zero, and 6/6 cache-busted probes returned HTTP 200, body `[]`, header
`X-TechX-Degraded-Dependencies: ad`, plus a structured fallback log.

During AZ loss, both stateless NodePools were fenced to the surviving AZ before
the 300-second acceptance interval. Thirteen first-party Deployment Pods were
evacuated from two `us-east-1a` nodes in 26.462 seconds. No replacement node
entered the fault AZ. Cleanup restored both NodePools; one node was uncordoned
and one was explicitly recorded as replaced. The final recovery snapshot had
all Argo applications Healthy, all Deployments Available, all current nodes
Ready/uncordoned, CoreDNS 2/2 across two AZs, flagd 1/1, and zero failed Jobs.

## Diagnostic runs excluded from acceptance

- `reliability-20260724-182851`: first AZ attempt stopped before its acceptance
  window because the harness checked asynchronous deletion too early.
- `reliability-20260724-185120`: post-baseline node convergence.
- `reliability-20260724-190043`: baseline aborted when the node set changed.

Each directory contains a README explaining why it is not acceptance evidence.

## Mentor reproduction

Run only in an approved protected window, never concurrently:

```powershell
$ctx = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"

./scripts/mandate17-inventory.ps1 -KubeContext $ctx
./scripts/mandate17-coredns-readiness.ps1 -KubeContext $ctx

./scripts/mandate17-dependency-chaos.ps1 `
  -KubeContext $ctx `
  -Dependency ad `
  -ProbeUri "<public-storefront>/api/data" `
  -Execute

./scripts/mandate17-az-chaos.ps1 `
  -KubeContext $ctx `
  -Zone us-east-1a `
  -HoldSeconds 300 `
  -EvacuationTimeoutSeconds 120 `
  -CapacityApproved `
  -FenceProvisioning `
  -Execute `
  -Confirm:$false

./scripts/mandate17-attacker-test.ps1 -KubeContext $ctx -Execute
```

`-WhatIf` remains non-mutating. Every mutating script has an explicit
production execution guard and cleanup in `finally`. Do not place secrets,
tokens, authorization headers, webhook URLs, or customer data in evidence.
