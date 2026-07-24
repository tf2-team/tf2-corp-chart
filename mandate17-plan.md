# Mandate 17 — Completion plan

## 1. Source of truth and constraints

The mentor source of truth is
`mandates/MANDATE-17-resilience-and-containment.md`. Completion requires:

1. an optional dependency may fail while browse/cart/checkout keeps SLO through
   deadline, fallback and explicit degradation;
2. loss of an entire AZ keeps DNS and the money path within SLO;
3. NetworkPolicy limits lateral movement and arbitrary egress;
4. workload identity, token and RBAC remain least privilege.

Do not lower SLO, mutate flagd, widen networks without a proven need, add
infrastructure only for evidence, overlap dependency and AZ faults, or include
secrets/customer payloads in evidence.

## 2. Authoritative current state — 24/07/2026

| Component | Revision |
|---|---|
| Platform | `e3f6f5142511a58ea3b51e3ab864f530dc3a71ff` |
| Chart/Argo production | `4899e054f43d3af3795f4aced5b41f0f7861f0d4` |
| Infra | `5e07b2cfe1ec54a00638dd45e96638abd59e8f74` |
| Final AZ harness | `0d85f980001507ec2dfb18fd95c45049d9f0e377` |

Production after the final recovery window:

- Locust was stopped at `0 users` before the fault and was not restarted by
  Mandate 17.
- All nine Argo applications are `Synced/Healthy`.
- Every Deployment is Available/updated.
- Every current node is Ready and uncordoned.
- Both stateless NodePools are restored to `us-east-1a` and `us-east-1b`.
- CoreDNS is 2/2 across two nodes/two AZs; flagd is 1/1.
- Latest runtime-hardening scans pass and failed Job count is zero.
- C2 remains live:
  `networkPolicy.enabled=true`,
  `networkPolicy.enforceEgress=true`,
  `egressProxy.enabled=true`.

## 3. Completed gates

### R0 — Clean entry gate: PASS

The authoritative five-minute baseline is
`docs/evidence/mandate-17/reliability-20260724-190910`:

- 601 iterations;
- browse/cart/checkout 100%;
- browse p95 316.42 ms;
- zero failed requests and zero dropped iterations;
- seven-node set unchanged for the full window;
- Argo Healthy, Deployments Available, nodes Ready/uncordoned, Locust stopped.

The immediate capacity review found approximately 3420m free requested CPU and
10.25 GiB free requested memory in surviving `us-east-1b`, versus 1390m CPU
and 1.63 GiB requested by 13 selected Pods. `requiresScaleOut=false`.

### R1 — Optional dependency fault and recovery: PASS

Authoritative evidence:
`reliability-20260724-150008/dependency-ad`.

- `ad` desired replicas remained two and Ready endpoints reached zero.
- 6/6 cache-busted probes returned HTTP 200, body `[]`, and
  `X-TechX-Degraded-Dependencies: ad`.
- Structured fallback log was captured.
- k6: 600/600 browse/cart/checkout 100%, browse p95 525.46 ms, no dropped
  iterations.
- Cleanup restored `ad` 2/2 and Argo Healthy.

`ad` was the minimum-risk optional dependency: it has an explicit fallback
contract, no HPA ownership conflict, and does not alter the money path itself.

### R2 — Whole-AZ loss and recovery: PASS

Authoritative evidence:
`reliability-20260724-190910/az-us-east-1a`.

The final harness fixed the only invalid-run race by waiting for actual Pod
evacuation before opening the acceptance window. With explicit approval, the
run used:

```powershell
./scripts/mandate17-az-chaos.ps1 `
  -Zone us-east-1a `
  -HoldSeconds 300 `
  -EvacuationTimeoutSeconds 120 `
  -CapacityApproved `
  -FenceProvisioning `
  -Execute `
  -Confirm:$false
```

Results:

- both stateless NodePools fenced to surviving `us-east-1b`;
- two fault nodes and 13 first-party Deployment Pods evacuated in 26.462s;
- no replacement node entered the fault AZ during the 300s hold;
- k6: 1200 iterations, browse/cart 100%, checkout 1199/1200 (99.9167%),
  browse p95 311.46 ms, zero dropped iterations;
- DNS and flagd stayed Ready;
- cleanup restored both NodePools; one node uncordoned, one explicitly recorded
  as `NotFound/replaced`.

One checkout failed the HTTP-200-with-order check but remained inside the
required >=99% SLO. The test stored aggregate output only, and Prometheus
recorded no non-200 handler increment, so no application/payment root cause is
claimed. The independent five-minute recovery run then passed 600/600
browse/cart/checkout at 100%, browse p95 308.61 ms, with no failed requests or
dropped iterations.

### C2 containment and identity: PASS

- Positive network matrix preserves the declared storefront, ops,
  observability, DNS, flagd, data and exact Kubernetes API consumer paths.
- Attacker can use DNS only; service lateral movement, Argo, Kubernetes API,
  egress proxy, Internet, RDS, MSK and Valkey are blocked.
- Attacker has no Kubernetes token and cannot read Secrets.
- 21/21 first-party identity/token/RBAC checks pass.
- Scoped IRSA checks pass for checkout, product-reviews and shopping-copilot.
- Attacker resources are cleaned up in `finally`.

## 4. Invalid runs — do not count as PASS

- `reliability-20260724-182851`: baseline passed, but the first AZ attempt
  stopped before the acceptance window because Pod deletion was still in
  progress; cleanup passed.
- `reliability-20260724-185120`: post-baseline node convergence; diagnostic.
- `reliability-20260724-190043`: node set changed during baseline; aborted
  before fault injection.

These artifacts are retained and clearly labelled to preserve audit history.

## 5. Only remaining work

No further live chaos, image promotion, application change, network widening,
or infrastructure change is required.

1. [x] Update evidence index and resilience narrative with exact revisions,
   timestamps, SLO, capacity, fault boundary, cleanup and recovery.
2. [x] Mark diagnostic runs as excluded from acceptance.
3. [x] Run the complete local/static CI suite on the final evidence branch.
4. [x] Review the diff for credentials and oversized/unnecessary artifacts.
5. [x] Commit/push the evidence branch and create evidence PR #262.
6. [ ] GitHub CI passed; obtain the required independent review, merge PR #262,
   and record the merged SHA.

If final static CI fails, fix only the proven documentation/script issue and
rerun it. Do not reopen a production fault gate for a local evidence-pack
failure.

## 6. Definition of Done

- [x] Dependency fault proves fallback body/header/log and preserves money-path
  SLO.
- [x] Whole-AZ loss preserves DNS and browse/cart/checkout SLO.
- [x] AZ fencing, uncordon/replacement handling and recovery proof pass.
- [x] C2 containment and attacker matrix pass.
- [x] Least-privilege ServiceAccount/RBAC/token/IRSA pass.
- [x] Flagd, exposure and observability checks pass.
- [x] Evidence index, rollback proof and mentor reproduction are complete on
  the branch.
- [ ] Evidence PR #262 has passed CI; required review and merge remain.

Mandate 17 is technically complete; administrative completion occurs when the
single evidence PR is merged.
