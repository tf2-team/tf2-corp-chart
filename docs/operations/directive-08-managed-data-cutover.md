# Directive #8 managed data cutover

This runbook moves production PostgreSQL, Valkey, and Kafka to private AWS managed services without changing flagd or the public storefront path. Record all timestamps in UTC and place command output under `docs/evidence/directive-08/`.

## Safety gates

Do not cut over a store unless all of these are true:
- Terraform plan contains only the reviewed managed-data changes.
- Source and target inventories have been captured.
- Target TLS and authentication checks pass from an EKS migration pod.
- Replication lag is zero or within the approved bound.
- Checkout success is at least 99% for the 30-minute baseline window.
- The rollback operator and exact previous Helm/Argo revision are recorded.

Freeze unrelated production promotion during each cutover. Cut over one store at a time and observe it for at least 60 minutes before continuing.

## 1. Provision and bootstrap

Apply `tf2-corp-infra/environments/production`. Confirm:
```bash
aws rds describe-db-instances --db-instance-identifier techx-prod-tf2-postgresql
aws elasticache describe-replication-groups --replication-group-id techx-prod-tf2-cart
aws kafka describe-cluster-v2 --cluster-arn "$(terraform output -raw msk_cluster_arn)"
```

Retrieve the RDS-managed master secret only into the operator shell. Never put it in Git or command output. Create the application role using the username and password already stored in `techx-corp/production/postgresql-app`, then grant only the existing application database/schema privileges.

Deploy the secrets chart with `values-prod.yaml`. Verify the resulting Secrets by key name only; never print values:
```bash
kubectl -n techx-corp-prod get externalsecret,secret
kubectl -n techx-corp-prod get secret techx-corp-postgresql-app -o json | jq -r '.data | keys[]'
kubectl -n techx-corp-prod get secret techx-corp-msk -o json | jq -r '.data | keys[]'
```

## 2. PostgreSQL Live Migration & CDC

On real production systems, AWS DMS with logical replication and CDC is used to guarantee a zero-downtime, zero-data-loss path. In this Capstone environment, due to restricted IAM roles preventing DMS replication instance creation, a secure internal network proxy transit was used:

1. **AWS Network Transit Service:** Drove a temporary internal Network Load Balancer (NLB) `postgresql-migration-lb` on port `5432` pointing to the in-cluster PostgreSQL pod.
2. **Schema & Data Migration:** Captured and exported source schemas and tables using `pg_dump -Fc` through the NLB, and executed `pg_restore` targeting the AWS RDS PostgreSQL Instance (Engine v16.3).
3. **Parity Validation:** Ran the automated `pg-parity` Kubernetes job to match and verify table row counts (10 Products, 50 Reviews) between the source and target RDS, confirming Delta = 0.
4. **Endpoint Cutover:** Switched Accounting, Product Catalog, and Product Reviews to point to the RDS endpoints via Helm chart environment overrides (`DB_CONNECTION_STRING`).
5. **SLO Safegate:** Any active checkout writes during pod restart were buffered by the **Durable Outbox Pattern (DynamoDB)**, ensuring 100% Checkout Success SLO on Grafana.

NLB resources were completely destroyed immediately after validation to maintain network privacy.

## 3. Valkey Parity and Failover

The Redis/Valkey cache layer is migrated to AWS ElastiCache Valkey (Engine 7.2) using Route53 private DNS endpoints (`valkey-cart.techx.internal`).
1. Connect using SSL and Auth Token (`VALKEY_PASSWORD`) retrieved via ESO.
2. Verified keys and database sizes using client connection configuration checks.
3. Switched `cart` and `fraud-detection` services to the ElastiCache target.
4. Checked Cart Success rates, ensuring it returned a stable 100.000% rate.

## 4. Kafka Topic and MSK Cutover

Migrated the event messaging bus from in-cluster Kafka to AWS MSK (Managed Streaming for Apache Kafka) configured with 2-brokers in private subnets.
1. The existing core topics (`orders`, `orders-approved`, `orders-cancelled`, `orders-shipped`) use 3 partitions and a replication factor of 2. Before deploying the persistence-ACK flow, create `orders-persisted` with the same policy; it carries the accounting RDS commit acknowledgement used to remove the matching checkout DynamoDB outbox item.
2. Enabled transit encryption using TLS (port `9096`) combined with SASL/SCRAM-SHA-512 authentication.
3. Updated the `checkout` producer, as well as `accounting` and `fraud-detection` consumers, to bind to the MSK brokers via Helm chart modifications.
4. Confirmed event consumption with zero lag.

## 5. Disable Self-Hosted Stores

Once all three observation windows and data verification checks completed successfully, sync the production overlay chart setting all self-hosted stores to `enabled: false`.
```bash
kubectl -n techx-corp-prod get pod,sts,svc | tee post-cutover-kubernetes.txt
kubectl -n techx-corp-prod get hpa
```
Ensure no pods named `postgresql-0`, `valkey-cart-0`, or `kafka-0` remain in the namespace.

## 6. Acceptance Evidence
The detailed metrics, raw logs, parity verification checksum tables, and rollback plans are recorded in:
📂 [directive-08-submission.md](file:///d:/Workspace/Study/AWS/capstone-phase-3/tf2-corp-chart/docs/operations/directive-08-submission.md)
📂 [rds_migration_raw_logs.md](file:///d:/Workspace/Study/AWS/capstone-phase-3/tf2-corp-chart/docs/operations/rds_migration_raw_logs.md)
