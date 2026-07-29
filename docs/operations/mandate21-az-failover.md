# Mandate 21 AZ failover and FIS skip-all runbook

## Safety boundary

Git and Argo CD are the only mutation path for the capacity probe. `kubectl` and Helm commands in this workflow are read-only. Starting even an AWS FIS `skip-all` experiment changes AWS state and requires separate immediate approval for the exact account, region, four template IDs, and evidence pack.

The active gate has exactly two approvals: `CapacityApproved = PASS` and `ChangeApproved = PASS`. The approval JSON rejects unknown fields and therefore rejects `CostApproved`. It expires no more than 24 hours after approval.

## Read-only infrastructure and capacity preparation

```cmd
cd /d techx-corp-chart
pwsh -NoProfile -File scripts\collect-infra-preflight.ps1 -ClusterName techx-tf2-prod -Revision <INFRA_GIT_SHA>
pwsh -NoProfile -File scripts\run-capacity-probe.ps1 -Mode GenerateConfiguration -Direction 1a-to-1b -RunId <RUN_ID> -SourceRevision <BASELINE_GIT_SHA>
```

Reviewing and copying the generated enable values, committing, and pushing require separate approval. Wait for Argo `Synced/Healthy`, then measure with distinct baseline and deployed revision bindings:

```cmd
pwsh -NoProfile -File scripts\run-capacity-probe.ps1 -Mode Measure -Direction 1a-to-1b -RunId <RUN_ID> -SourceRevision <BASELINE_GIT_SHA> -DeployedRevision <DEPLOYED_CHART_GIT_SHA>
```

Restore `values-capacity-probe.yaml` to `enabled: false` through an approved Git change and Argo reconciliation before repeating `1b-to-1a`. `CapacityApproved` requires both direction-specific PASS artifacts and final disabled desired state.

## Contract and approval preparation

Verify the checked-in contract against all four live templates without writing evidence:

```cmd
pwsh -NoProfile -File scripts\sync-mandate21-fis-contract.ps1
```

The fixed execution order is:

1. `1a-primary-in` — `EXT2UboGoZ7ErXaQ`
2. `1a-primary-outside` — `EXT2cGQZ1Hb4HKCC`
3. `1b-primary-in` — `EXTDqvVeTfQiN7zBS`
4. `1b-primary-outside` — `EXT34dobGM9bVqZ2`

Create approval JSON conforming to `scripts/mandate21-fis-approval.schema.json`. Bind it to account, region, cluster, chart and infra SHAs, canonical contract hash, all four live template hashes/timestamps, infra evidence, both capacity directions, and the three immutable-audit alarms remaining `OK` for their complete evaluation windows.

## Read-only wrapper preflight

Without `-Execute`, the wrapper reads identity and all four FIS templates, computes revision hashes, and never starts an experiment or writes synthetic cleanup evidence:

```cmd
pwsh -NoProfile -File scripts\mandate21-fis-drill.ps1
```

## Four real skip-all experiments

The following command is state-changing. Obtain immediate approval before running it. Replace every placeholder with the exact reviewed artifact:

```cmd
pwsh -NoProfile -File scripts\mandate21-fis-drill.ps1 -Execute -ActionsMode skip-all -ApprovalFile <APPROVAL_JSON> -ChartGitSha <40_HEX_SHA> -InfraGitSha <40_HEX_SHA> -InfraPreflightPath <INFRA_JSON> -Capacity1aTo1bPath <CAPACITY_1A_TO_1B_JSON> -Capacity1bTo1aPath <CAPACITY_1B_TO_1A_JSON> -AuditEvidencePath <AUDIT_JSON>
```

The wrapper starts one template at a time with `actionsMode=skip-all`, polls it to terminal, and fails before starting the next variant if the current one is not `completed`. Each record includes experiment ID/state, template hash/timestamp, target summary returned by FIS, stop alarms, and `cleanupStatus=NOT_APPLICABLE`. Aggregate PASS requires four completed records in the fixed order.

Skip-all validates target resolution and orchestration only. It does not prove action permissions, application RTO, durability, or cleanup for a live fault. `run-all` remains an explicit live-fault mode but this implementation deliberately refuses to start it; a separate reviewed live-drill procedure and approval are required.

## Abort and evidence rules

Do not use direct cleanup mutations, alarm-state forcing, SQS purge, replay, Helm mutation, or kubectl mutation. Preserve the wrapper JSON, approval artifact, contract/live metadata, infra and capacity evidence, and audit window evidence. The historical readiness report must never be rewritten to imply a preview ran when it did not.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented the two-gate, four-template real skip-all workflow and explicit state-change boundary. -->