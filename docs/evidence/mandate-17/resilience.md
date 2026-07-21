# Mandate 17 resilience evidence

## Scope

This file records the read-only production preflight and local resilience test
results completed on 2026-07-21. It does not claim that dependency or AZ chaos
has passed. Those tests require an approved change window, a named rollback
operator, active load, and fault-window SLO evidence.

## Revisions and release artifact

| Item | Verified value |
|---|---|
| Platform `origin/main` | `61da855` |
| Platform resilience merge | `ba6dd5b` (PR #54) |
| Chart `origin/main` and Argo target | `022aa8a` |
| Infra `origin/main` | `4d24373` |
| VPC CNI NetworkPolicy merge | `d6ddda3` (PR #102) |
| Frontend image | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/frontend:sha-ba6dd5b` |
| Frontend ECR digest | `sha256:4cd1cd02fdca08e48ec3888c5e24a77aaef0346695920e5a88c7985eaa4b929f` |

All four Argo CD applications were `Synced/Healthy` at revision `022aa8a`.
The live frontend Deployment used the image and digest listed above, and
`OPTIONAL_DEPENDENCY_TIMEOUT_MS` was `500`.

## Local resilience verification

The completion branch adds gateway and API-route coverage in addition to the
existing optional-dependency helper tests.

```powershell
cd D:\tf2-corp-platform\tf2-corp-platform\src\frontend
npm ci
npm run test:resilience
npx tsc --noEmit
npm run build
```

Observed result:

- 10/10 resilience tests passed.
- Ad and recommendation gateways applied a deadline approximately 500 ms in
  the future.
- Availability/deadline failures returned HTTP 200, an empty list, and the
  expected degraded-dependency header.
- Non-degradable errors propagated.
- Recommendation fallback did not call product catalog.
- TypeScript compilation and the Next.js production build passed.

The clean install reported the frontend dependency findings already present in
the npm dependency tree. No broad dependency upgrade or `npm audit fix` was
performed as part of this scoped resilience change.

## Identity, token, and RBAC inventory

Command:

```powershell
$env:KUBECONFIG = "$env:TEMP\codex-m17-kubeconfig"
./scripts/mandate17-inventory.ps1 -KubeContext techx-tf2-prod
```

Observed result:

- 21/21 rendered first-party workloads used a dedicated ServiceAccount.
- Pod and ServiceAccount token automount checks passed.
- All dangerous live `auth can-i` checks returned `no` for all 21 identities.
- No wildcard or unexpected application RBAC binding was found by the
  inventory.

## IRSA preflight

| Workload | IAM role | Projected STS token | Default K8s token |
|---|---|---|---|
| checkout | `techx-prod-tf2-checkout-outbox` | Present, read-only | Disabled |
| product-reviews | `techx-prod-tf2-product-reviews-model-read` | Present, read-only | Disabled |
| shopping-copilot | `techx-prod-tf2-shopping-copilot-model-read` | Present, read-only | Disabled |

Each Pod had `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, an
`sts.amazonaws.com` projected token volume, and
`automountServiceAccountToken=false`. The previous 30 minutes of logs had no
`AccessDenied`, `NoCredential`, `InvalidIdentityToken`, or `ExpiredToken`
match. A fault-window functional IRSA smoke test remains required.

## Read-only traffic baseline

Prometheus five-minute baseline before any fault:

| Signal | Observed value |
|---|---:|
| Frontend non-5xx rate | 100% |
| Frontend p95 | approximately 36 ms |
| Frontend request rate | approximately 2.5 requests/second |

Three internal black-box GET probes to `/`, `/api/data`, and
`/api/recommendations` returned HTTP 200 with no degraded header. This is a
smoke baseline only. The traffic rate and sample count are not sufficient to
replace the required Locust baseline/fault/recovery evidence.

## AZ and DNS preflight

The cluster had three Ready nodes in each of `us-east-1a` and `us-east-1b`.
Observed placement:

| Workload | Ready | AZ placement |
|---|---:|---|
| cart | 2/2 | both in `us-east-1b` |
| checkout | 2/2 | one per AZ |
| frontend | 3/3 | one in `1a`, two in `1b` |
| frontend-proxy | 2/2 | one per AZ |
| payment | 2/2 | one per AZ |
| product-catalog | 2/2 | both in `us-east-1b` |
| shipping | 2/2 | one per AZ |
| CoreDNS | 2/2 | same node in `us-east-1b` |

CoreDNS already had preferred hostname anti-affinity and soft zone spread.
The current co-location is runtime placement drift; Kubernetes does not
automatically rebalance already-running Pods when capacity returns. A reviewed,
one-Pod-at-a-time CoreDNS/workload rebalance and a surviving-zone capacity
check are required before testing loss of `us-east-1b`.

Node CPU was low, but several nodes showed high current memory use (up to 94%).
Actual usage alone is not capacity approval. Requested resources, allocatable
capacity, Pending events, and scale-up policy must be reviewed for the fault
window.

## Dependency chaos dry-run

The script was corrected so `-WhatIf` does not execute the restore scale when
no fault was injected. The dry-run compared the ad Deployment before and after:

```text
before=5339867:87:2
after=5339867:87:2
unchanged=True
```

Ad is a fixed two-replica Deployment and is suitable for the approved demo.
Recommendation has an active HPA and must not be scaled directly without an
approved HPA/Argo ownership procedure.

## Remaining production gates

- Approve a change window and name both the fault operator and rollback
  operator.
- Confirm rolling error budget and active incident status.
- Rebalance CoreDNS and the co-located money-path replicas, then verify normal
  placement.
- Approve surviving-zone capacity using requests/allocatable data.
- Run Locust warm-up, dependency fault, and recovery windows; capture CSV and
  Prometheus/Grafana data for the exact timestamps.
- Run dependency faults separately and restore fully before any AZ fault.
- Run AZ chaos only with `-CapacityApproved -Execute` and verify every cordoned
  node is uncordoned.
- Re-run IRSA, storefront exposure, observability, and flagd checks during and
  after each fault.

No secret, token, authorization header, webhook, or raw customer data belongs
in this evidence directory.
