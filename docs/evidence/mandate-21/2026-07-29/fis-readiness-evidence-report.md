# Mandate 21 FIS Readiness Evidence Report

## Executive result

**Evidence capture:** 2026-07-29, approximately 17:27-17:39 ICT  
**AWS account:** `493499579600`  
**Region:** `us-east-1`  
**Cluster context:** `arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod`  
**Overall decision:** **NO-GO / FAIL**

This report records the observed live state. It does not mark a requested gate
`PASS` when the live evidence does not satisfy it. Only read-only AWS,
Kubernetes, Git, and local inspection was performed. No FIS experiment,
including `actionsMode=skip-all`, was started.

| Required evidence group | Result | Reason |
|---|---|---|
| FIS execution pack | **FAIL** | Four live templates exist, but the checked-in contract contains four obsolete IDs, no FIS experiment history exists, and no cleanup-state artifact was produced. |
| Infrastructure preflight | **FAIL** | Route/NAT and managed-store checks pass, but the controlled surviving-AZ capacity probe is absent. The collector also contains stale Valkey and MSK default names. |
| Gate approval | **FAIL** | `CapacityApproved` and `ChangeApproved` have no approval artifact; the cost forecast is `393.779034 USD/7 days`, above the `300 USD` ceiling. |
| Immutable-audit gate | **FAIL** | Only health-check Errors is `OK`; control-health and health Lambda DLQ are `ALARM`. |

## 1. FIS execution pack

### 1.1 Contract drift

At the original evidence capture, the checked-in `scripts/mandate21-fis-contract.json` referenced these obsolete IDs; it was corrected after capture:

| Variant | Contract ID | Live lookup |
|---|---|---|
| `1a-primary-in` | `EXT33xYmxJVCDMiQ` | `ResourceNotFoundException` |
| `1a-primary-outside` | `EXTvCVv3L4aYWBa` | `ResourceNotFoundException` |
| `1b-primary-in` | `EXT3V4aApSKJaBnp` | `ResourceNotFoundException` |
| `1b-primary-outside` | `EXT2eK437rucfP5a` | `ResourceNotFoundException` |

The account currently contains four different Terraform-managed templates.
The revision hashes below are SHA-256 values over a recursively key-sorted,
compact JSON serialization of the live `experimentTemplate` object captured
during this evidence run.

| Variant | Live template ID | AWS last update (ICT) | Revision SHA-256 |
|---|---|---|---|
| `1a-primary-in` | `EXT2UboGoZ7ErXaQ` | `2026-07-29T16:33:08.205+07:00` | `22873c683fa034843990d906c49b1c89a11d82b0fef05151d27cba48819e58dd` |
| `1a-primary-outside` | `EXT2cGQZ1Hb4HKCC` | `2026-07-29T16:33:08.239+07:00` | `35691140cc4e0a04f49e6dbcb4fb969672d94f52d99cf14e8aa564cc8c9b0ead` |
| `1b-primary-in` | `EXTDqvVeTfQiN7zBS` | `2026-07-29T16:33:08.261+07:00` | `4357893630d1d2eb9d5d9c45f3b2f831f900ca58a9878cfa1385b07a0ad58127` |
| `1b-primary-outside` | `EXT34dobGM9bVqZ2` | `2026-07-29T16:33:08.274+07:00` | `fd9bd879c6df1cc78f9004cb68431a2af89a7930401aa0072a767273bcd1901b` |

All four live templates use:

- execution role `arn:aws:iam::493499579600:role/techx-prod-tf2-fis-execution-role`;
- `accountTargeting=single-account`;
- `emptyTargetResolutionMode=fail`;
- tag `CleanupPolicy=fis-native-verify-v1`;
- S3 FIS logging below a variant-specific `mandate-21/fis/` prefix.

### 1.2 Target selectors

| Variant | EC2 selector | Subnet selector | Valkey selector | RDS selector |
|---|---|---|---|---|
| `1a-primary-in` | Cluster tag `kubernetes.io/cluster/techx-tf2-prod=shared`; `State.Name=running`; `Placement.AvailabilityZone=us-east-1a`; `ALL` | `subnet-0d1f0d1de6b352021`, `subnet-07599236e4979c4b2`; `ALL` | tag `Name=techx-prod-tf2-cart`; `availabilityZoneIdentifier=us-east-1a`; `ALL` | tag `Name=techx-prod-tf2-postgresql`; `availabilityZoneIdentifiers=us-east-1a`; `ALL` |
| `1a-primary-outside` | Same `1a` EC2 selector | Same `1a` subnets | Same `1a` Valkey selector | Intentionally absent |
| `1b-primary-in` | Cluster tag `kubernetes.io/cluster/techx-tf2-prod=shared`; `State.Name=running`; `Placement.AvailabilityZone=us-east-1b`; `ALL` | `subnet-0ab17749536b34693`, `subnet-0ee04e7bc69e247a3`; `ALL` | tag `Name=techx-prod-tf2-cart`; `availabilityZoneIdentifier=us-east-1b`; `ALL` | tag `Name=techx-prod-tf2-postgresql`; `availabilityZoneIdentifiers=us-east-1b`; `ALL` |
| `1b-primary-outside` | Same `1b` EC2 selector | Same `1b` subnets | Same `1b` Valkey selector | Intentionally absent |

The `primary-in` variants include forced classic Multi-AZ RDS failover through
`aws:rds:reboot-db-instances` with `forceFailover=true`. The outside variants
omit both the RDS target and RDS action. All variants include EC2 stop/restart,
two-minute subnet disruption, and ten-minute Valkey AZ interruption.

### 1.3 Stop-alarm ARNs

Every live template has the same four stop conditions:

| Alarm ARN | Live state |
|---|---|
| `arn:aws:cloudwatch:us-east-1:493499579600:alarm:techx-prod-tf2-storefront-5xx-ratio` | `OK` |
| `arn:aws:cloudwatch:us-east-1:493499579600:alarm:techx-prod-tf2-storefront-healthy-hosts` | `OK` |
| `arn:aws:cloudwatch:us-east-1:493499579600:alarm:techx-prod-tf2-mandate12-immutable-audit-control-health` | **`ALARM`** |
| `arn:aws:cloudwatch:us-east-1:493499579600:alarm:techx-prod-tf2-accepted-order-durability-gap` | `OK` |

Because one required stop alarm is already `ALARM`, the templates are not ready
for preview or live fault execution.

### 1.4 Skip-all results and cleanup state

`aws fis list-experiments` returned an empty collection at capture time.
Therefore no completed `actionsMode=skip-all` run can be attributed to any of
the four templates.

| Variant | Skip-all result | Experiment ID | Cleanup state |
|---|---|---|---|
| `1a-primary-in` | **PENDING / NOT RUN** | None | `NOT_PRODUCED` |
| `1a-primary-outside` | **PENDING / NOT RUN** | None | `NOT_PRODUCED` |
| `1b-primary-in` | **PENDING / NOT RUN** | None | `NOT_PRODUCED` |
| `1b-primary-outside` | **PENDING / NOT RUN** | None | `NOT_PRODUCED` |

The `CleanupPolicy=fis-native-verify-v1` template tag is configuration, not
runtime cleanup proof. A `skip-all` run should produce a terminal FIS
experiment record and a `cleanup-state.json` result of `NOT_APPLICABLE`.
Starting such a preview changes AWS state and was outside the approved
read-only scope of this capture.

## 2. Infrastructure preflight

### 2.1 Route and NAT by AZ — PASS

VPC: `vpc-0eef6ab7c99ef3bf4`

| AZ | Private subnets | Private route table | Active default route | Same-AZ NAT |
|---|---|---|---|---|
| `us-east-1a` | `subnet-07599236e4979c4b2`, `subnet-0d1f0d1de6b352021` | `rtb-0cec0db5d4a189896` | `0.0.0.0/0 -> nat-0b043c6cb1b44c240` | `nat-0b043c6cb1b44c240`, `available`, public subnet `subnet-0366a5b003f74e12a` |
| `us-east-1b` | `subnet-0ee04e7bc69e247a3`, `subnet-0ab17749536b34693` | `rtb-09bfd614874994f6c` | `0.0.0.0/0 -> nat-0f857f477664c05af` | `nat-0f857f477664c05af`, `available`, public subnet `subnet-08656b25f8d0ddfc1` |

Each private subnet routes through an available NAT gateway in its own AZ.

### 2.2 Capacity and Karpenter — PENDING

Current-state evidence is healthy:

- eight Ready nodes: five in `us-east-1a` and three in `us-east-1b`;
- four Ready Karpenter NodeClaims: three in `us-east-1a`, one in `us-east-1b`;
- `stateless-on-demand` and `stateless-spot` NodePools are `Ready` and allow
  both AZs, each with limits of 32 CPU and 64 GiB;
- Karpenter controller Deployment is `2/2 Available`, with one controller pod
  in each AZ;
- no Pending pods or current `FailedScheduling` events were observed.

This does **not** satisfy the required surviving-AZ capacity proof:

- Deployment `techx-corp-prod/capacity-probe` does not exist;
- no controlled lost-AZ load plus 20% headroom was scheduled into each
  surviving AZ;
- no five-minute readiness/stability window or new surviving-AZ NodeClaim
  attribution exists.

Result: **`CapacityApproved = PENDING`, not PASS.**

### 2.3 Managed stores

| Service | Live evidence | Result |
|---|---|---|
| RDS | `techx-prod-tf2-postgresql`; `available`; primary `us-east-1a`; secondary `us-east-1b`; Multi-AZ; encrypted; deletion protection; seven-day backups | **PASS** |
| Valkey | `techx-prod-tf2-cart`; `available`; automatic failover and Multi-AZ enabled; primary `us-east-1b`; replica `us-east-1a`; at-rest and in-transit encryption enabled | **PASS** |
| DynamoDB | `techx-prod-tf2-checkout-outbox`; `ACTIVE`; deletion protection enabled; KMS encryption; PITR enabled with 35-day recovery period | **PASS** |
| MSK | `techx-prod-tf2-msk`; `ACTIVE`; two brokers across `use1-az1` and `use1-az2`; private access; TLS client/broker and in-cluster encryption; encrypted EBS | **PASS** |

At original capture, the checked-in collector defaults were stale; they were corrected after capture:
`ValkeyReplicationGroupId=techx-corp-valkey` and
`MskClusterName=techx-corp-msk`, while the live resources are
`techx-prod-tf2-cart` and `techx-prod-tf2-msk`. The Valkey lookup with the
default failed with `ReplicationGroupNotFoundFault`. Consequently, a generated
collector-level `overallStatus=PASS` is not available.

## 3. Gate approval

At evidence-capture time, no revision-bound approval artifact existed. The current active approval contract has exactly two gates:

| Approval | Required value | Capture-time evidence | Result |
|---|---|---|---|
| `CapacityApproved` | `PASS` | Controlled surviving-AZ capacity probe absent | **PENDING** |
| `ChangeApproved` | `PASS` | No signed, revision-bound approval artifact | **PENDING** |

The post-capture implementation intentionally excludes cost approval from the FIS execution gate. This historical report does not retroactively mark either active approval as passed.
## 4. Immutable-audit gate

The required evaluation window is two periods of 300 seconds.

| Alarm | State | Recent metric evidence | Evaluation-window result |
|---|---|---|---|
| `techx-prod-tf2-mandate12-immutable-audit-health-check-errors` | `OK` | Ten consecutive captured five-minute datapoints at `0` between 16:35 and 17:30 ICT | **PASS** |
| `techx-prod-tf2-mandate12-immutable-audit-health-lambda-dlq-visible` | `ALARM` | Fourteen captured five-minute datapoints remained at `701` visible messages between 16:30 and 17:35 ICT | **FAIL** |
| `techx-prod-tf2-mandate12-immutable-audit-control-health` | `ALARM` | Ten captured five-minute datapoints remained at health value `0` between 16:35 and 17:30 ICT; the alarm requires a value not below `1` | **FAIL** |

Result: **Audit gate FAIL.** The condition “three immutable-audit alarms are
`OK` for the complete evaluation window” is not met.

## 5. Required remediation before a new evidence pack

1. Regenerate a fail-closed infrastructure preflight artifact from the configured EKS cluster.
2. Complete both sequential GitOps capacity directions and return the probe to disabled state after each.
3. Archive and drain the historical immutable-audit DLQs through the separately approved Object-Lock procedure, then wait for all three alarms to remain `OK` for the full window.
4. Produce a revision-bound approval artifact with `CapacityApproved=PASS` and `ChangeApproved=PASS`.
5. Obtain separate state-change approval, then run all four FIS previews sequentially with `actionsMode=skip-all` and record terminal experiment IDs plus `NOT_APPLICABLE` cleanup states.

Until every active item above passes, do not start a live FIS fault experiment.

<!-- Change trail: @hungxqt - 2026-07-29 - Updated post-capture remediation for the two-gate, four-template skip-all workflow. -->