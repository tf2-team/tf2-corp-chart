# Authoritative Mandate 17 baseline and AZ-loss run

This is the authoritative `4899e05` run. Times are Asia/Ho_Chi_Minh
(`UTC+07:00`) unless stated otherwise.

## Entry baseline

- Chart/Argo revision: `4899e054f43d3af3795f4aced5b41f0f7861f0d4`
- Platform revision: `e3f6f5142511a58ea3b51e3ab864f530dc3a71ff`
- Infra revision: `5e07b2cfe1ec54a00638dd45e96638abd59e8f74`
- Harness revision: `0d85f980001507ec2dfb18fd95c45049d9f0e377`
- Locust: `stopped`, `0 users`
- k6: 601 iterations; browse/cart/checkout 100%; browse p95 316.42 ms;
  zero failed requests and zero dropped iterations.
- The seven-node set was unchanged for the complete five-minute baseline.
- All Argo applications were `Synced/Healthy`, all Deployments were
  Available, all nodes were Ready/uncordoned, CoreDNS was 2/2 across two
  nodes/two AZs, and the latest inventory Job was Complete.

The surviving `us-east-1b` capacity snapshot showed approximately 3420m free
requested CPU and 10.25 GiB free requested memory. The 13 first-party
Deployment Pods selected in `us-east-1a` requested approximately 1390m CPU and
1.63 GiB memory, so no scale-out was required.

## AZ-loss execution

Command:

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

- Run start: `2026-07-24T19:18:45.7633840+07:00`
- Pod evacuation: `19:19:35.4256282` to `19:20:01.8871860`
  (26.462 seconds)
- Fault boundary: two `us-east-1a` nodes and 13 first-party Deployment Pods.
- Both stateless NodePools were fenced to `us-east-1b`; no replacement node
  entered the fault AZ during the 300-second acceptance window.
- k6: 1200 iterations; browse 100%; cart 100%; checkout
  1199/1200 (99.9167%); browse p95 311.46 ms; zero dropped iterations.
- DNS and flagd remained Ready.
- Cleanup restored both NodePool zone requirements. One surviving fault node
  was uncordoned; the other was recorded as `NotFound/replaced`.
- At `19:27:10.5006877`, the harness exited zero after all Deployment and
  cleanup gates passed.

The one failed checkout was below the approved 1% error budget. The k6 test
version used for this window stores aggregate status only, so it cannot prove
the exact response timestamp/body. Prometheus recorded no increment for a
non-200 `/api/checkout` handler response in the fault interval. The supported
conclusion is therefore a transient before handler instrumentation while Pods
were being evacuated; it is not evidence of an application or payment failure.
No root cause is assigned beyond what the artifacts prove.

## Recovery

An independent public-storefront recovery window ran from approximately
`19:36:43` to `19:42:09`:

- 600 iterations;
- browse/cart/checkout 100%;
- browse p95 308.61 ms;
- zero failed requests and zero dropped iterations.

The `19:42:56` recovery snapshot shows all Argo applications
`Synced/Healthy`, every Deployment Available/updated, every current node
Ready/uncordoned, both NodePools restored to both AZs, CoreDNS 2/2, flagd 1/1,
and zero failed Jobs.

## Artifact classification

- `baseline-k6-*`, `preflight.json`, and `capacity-review.json`: entry proof.
- `az-us-east-1a/fault-boundary.json`, `az-chaos-console.txt`,
  `nodepool-*-fenced.json`, and `pods-fault-window.txt`: fault proof.
- `az-us-east-1a/az-k6-*`: fault-window SLO proof.
- `az-us-east-1a/cleanup.json` and `nodepool-*-restored.json`: rollback proof.
- `az-us-east-1a/recovery-k6-*` and `recovery-state.json`: recovery proof.

No secret, token, authorization header, webhook URL, or customer payload is
stored in this directory.
