# Mandate 21 AZ failover — runtime runbook

This runbook owns only the Person 3 runtime, measurement, and evidence scope.
Person 1 owns the four reviewed FIS template variants, NAT/capacity/cost gates, and AWS
cleanup. Person 2 owns order durability, Accounting migration, application
metrics, and the reconciliation checker.

## Safety model

- `scripts/mandate21-fis-drill.ps1` is preview-only unless `-Execute` is set.
- Live execution additionally requires four approval switches and the
  case-sensitive token `RUN-M21-FIS`.
- The wrapper never cordons, drains, deletes, or reschedules Kubernetes objects.
  AWS FIS creates the actual AZ fault and its alarm stop conditions own abort.
- The live AZ is selected randomly inside the wrapper after all gates pass.
  Operators must not preselect it.
- Do not use `mandate17-az-chaos.ps1`; its pod/node simulation is not valid
  evidence for an AZ power interruption.

AWS FIS does not accept an AZ override on `start-experiment`, and an experiment
template cannot conditionally omit RDS failover based on the current primary
AZ. Person 1 must therefore provide four reviewed variants: two AZs multiplied
by `RDS primary in selected AZ` / `RDS primary outside selected AZ`. The wrapper
queries the current RDS primary after choosing the fault AZ and selects the only
valid variant:

```powershell
Copy-Item scripts/mandate21-fis-contract.example.json scripts/mandate21-fis-contract.json
# Replace all four EXT0 placeholders with Person 1's reviewed template IDs.
```

The production contract file contains environment-specific IDs and is
intentionally not the source of truth for the FIS templates. Template details
are re-read from AWS and validated during every preflight.

## CI and preview

```powershell
helm dependency build .
helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml
./tests/mandate21/verify-runtime.ps1

./scripts/mandate21-fis-drill.ps1 `
  -ContractPath ./scripts/mandate21-fis-contract.json
```

Preview verifies the exact cluster context, AWS identity, all Argo applications,
Deployment availability, no Pending pods, two-AZ placement for Accounting,
frontend-proxy, Linkerd, CoreDNS, ALB controller and Karpenter, public storefront
HTTP 200, both FIS templates, and alarm stop conditions. It creates no fault.

The `frontend-proxy` zone constraint remains `ScheduleAnyway`: it must be able
to collapse into the surviving AZ. The wrapper instead enforces baseline skew
of at most one immediately before the drill.

## External k6 ledger

Run k6 outside the cluster and outside the fault domain. Start it before FIS and
keep it running through baseline, fault, and recovery:

```bash
BASE_URL=https://hungtran.id.vn \
FAULT_ID=m21-pending \
LEDGER_ENABLED=true \
DURATION=40m \
k6 run --log-format raw \
  --console-output evidence/mandate21/ledger.jsonl \
  --summary-export evidence/mandate21/k6-summary.json \
  scripts/maintenance-load-test.js
```

Each checkout record follows the Person 2 reconciler contract:
`testRequestId`, `traceId`, `orderId`, `startedAt`, `completedAt`,
`httpStatus`, `durationMs`, fault ID, and outcome. It never contains card data,
credentials, email, address, or customer payload. `ambiguous` means the caller
cannot prove whether a request with no usable response was accepted; Person 2's
checker must resolve every such record from durable state.

## Live execution

All gates must be documented before this command:

1. Person 1: two-AZ NAT, single-AZ capacity, cost, FIS role/template and cleanup.
2. Person 2: migration/schema complete; after five quiet rollout minutes,
   controlled load runs for at least 15 minutes and produces at least 100
   accepted checkouts with zero `shipping_pkey`, SQLSTATE `23505`, or
   `order_parse_failed`; no outbox item is older than 60 seconds and durability
   tests pass. Extend the load window when the minimum volume is not reached.
3. Person 3: chart Synced/Healthy, placement preview passes, dashboard and
   external k6 are recording.
4. Team change approval is open. The mentor reviews evidence; the team runs the
   experiment.

```powershell
# Build Person 2's reviewed Go reconciler before the change window.
Push-Location ../tf2-corp-platform/tools/mandate21-reconcile
go build -o ../../../tf2-corp-chart/bin/mandate21-reconcile.exe .
Pop-Location

./scripts/mandate21-fis-drill.ps1 `
  -ContractPath ./scripts/mandate21-fis-contract.json `
  -EvidenceDirectory ./evidence/mandate21 `
  -ReconcilerPath ./bin/mandate21-reconcile.exe `
  -LedgerPath ./evidence/mandate21/ledger.jsonl `
  -DynamoDbTable $env:CHECKOUT_OUTBOX_TABLE `
  -PostgresConnectionString $env:DB_CONNECTION_STRING `
  -JaegerUrl $env:JAEGER_QUERY_URL `
  -Execute `
  -CapacityApproved `
  -CostApproved `
  -DurabilityApproved `
  -ChangeApproved `
  -ConfirmationToken RUN-M21-FIS
```

The wrapper records the random AZ, AWS identity, FIS experiment ID, placement,
and before/after cluster snapshots. It polls FIS until terminal, then rejects
remaining Pending pods or cordoned nodes and invokes Person 2's checker.

## Dashboard and evidence

Open **Mandate 21 - AZ Failover**. Add one dashboard annotation at the exact FIS
start and one at the terminal time, using the wrapper's UTC timestamps and fault
ID. Export or capture:

- browse/cart/checkout success and storefront p95;
- Ready nodes and money-path pods per AZ;
- ALB healthy targets per AZ;
- RDS and Valkey signals;
- outbox age, Accounting errors, and accepted/durable/persisted/ambiguous totals;
- pod placement before, during, and after the fault.

The static YACE ALB dimensions in `values-prod.yaml` match the current
production ALB and target group. If Terraform recreates either resource, Person
1 must update those dimensions before preview; a zero/missing ALB series is a
failed observability gate, not permission to continue.

Final PASS requires FIS `completed`, SLO recovery within five minutes and for
three consecutive one-minute windows, zero dropped k6 iterations, Person 2's
equality proof:

```text
charged = unique accepted = durable = persisted
```

and deterministic runtime cleanup verification in `cleanup-state.json` with status `PASS`.
The drill wrapper automatically evaluates eight read-only checks (`fisPostActions`,
`networkAclRestored`, `ec2Recovered`, `rdsHealthy`, `valkeyHealthy`,
`stopAlarmsStable`, `kubernetesRecovered`, and `durabilityReconciliation`) without
performing any mutating AWS, Kubernetes, or Helm action.

No live run is complete until Person 1 confirms that FIS-managed NACL/EC2 state
is clean, `cleanup-state.json` is recorded as `PASS`, and Argo CD has no drift.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented deterministic runtime cleanup-state.json verification and fail-closed checks. -->
