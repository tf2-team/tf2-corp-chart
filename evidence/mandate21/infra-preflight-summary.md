# Mandate 21 Infrastructure Preflight

Account: 493499579600
Region: us-east-1
Cluster: techx-tf2-prod
Revision: 28abcd91383ca0df3c463b994a75801d03f706b1
Status: PASS

| Check | Status | Detail |
|---|---|---|
| cluster.unique | PASS | Configured EKS cluster must resolve exactly once. |
| cluster.vpc | PASS | VPC is derived from the configured EKS cluster. |
| cluster.subnets | PASS | EKS must expose at least one configured subnet. |
| network.privateSubnet.subnet-07599236e4979c4b2.sameAzNat | PASS | Exactly one active IPv4 default route must target an available NAT gateway in the same AZ. |
| network.privateSubnet.subnet-0ee04e7bc69e247a3.sameAzNat | PASS | Exactly one active IPv4 default route must target an available NAT gateway in the same AZ. |
| network.privateSubnet.subnet-0ab17749536b34693.sameAzNat | PASS | Exactly one active IPv4 default route must target an available NAT gateway in the same AZ. |
| network.privateSubnet.subnet-0d1f0d1de6b352021.sameAzNat | PASS | Exactly one active IPv4 default route must target an available NAT gateway in the same AZ. |
| network.subnetCoverage | PASS | Every EKS-configured subnet must have route evidence. |
| rds.unique | PASS | RDS identifier must resolve exactly once. |
| rds.available | PASS | RDS must be available. |
| rds.multiAz | PASS | RDS Multi-AZ must be enabled. |
| rds.encrypted | PASS | RDS storage encryption must be enabled. |
| rds.deletionProtection | PASS | RDS deletion protection must be enabled. |
| rds.backupRetention | PASS | RDS backup retention must be at least seven days. |
| valkey.unique | PASS | Valkey replication group must resolve exactly once. |
| valkey.available | PASS | Valkey must be available. |
| valkey.multiAz | PASS | Valkey Multi-AZ must be enabled. |
| valkey.automaticFailover | PASS | Valkey automatic failover must be enabled. |
| valkey.transitEncryption | PASS | Valkey transit encryption must be enabled. |
| valkey.atRestEncryption | PASS | Valkey at-rest encryption must be enabled. |
| dynamodb.unique | PASS | DynamoDB table must resolve exactly once. |
| dynamodb.active | PASS | DynamoDB must be ACTIVE. |
| dynamodb.deletionProtection | PASS | DynamoDB deletion protection must be enabled. |
| dynamodb.kms | PASS | DynamoDB KMS encryption must be enabled with a key identifier. |
| dynamodb.pitr | PASS | DynamoDB PITR must be ENABLED. |
| msk.unique | PASS | MSK cluster name must resolve exactly once. |
| msk.active | PASS | MSK must be ACTIVE. |
| msk.brokers | PASS | MSK must have at least two brokers. |
| msk.tls | PASS | MSK client-to-broker encryption must be TLS-only. |

<!-- Change trail: @hungxqt - 2026-07-29 - Generated revision-bound fail-closed infrastructure preflight evidence. -->
