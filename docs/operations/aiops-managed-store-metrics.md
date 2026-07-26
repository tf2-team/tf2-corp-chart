# AIOps managed-service metrics

Production exports activity, CPU, and network signals for the managed PostgreSQL, MSK, and Valkey dependencies.

## Collection paths

| Service | Activity signal | CPU and host network |
| --- | --- | --- |
| PostgreSQL | OTel `postgresql/rds` receiver | YACE from `AWS/RDS` |
| Kafka | OTel `kafkametrics` receiver | YACE from `AWS/Kafka` |
| Valkey | OTel `redis/valkey-cart` receiver | YACE from `AWS/ElastiCache` |

The OTel Collector is a DaemonSet, so every node may collect the same static managed endpoint. PromQL must use `max` or `avg` for duplicated PostgreSQL and Valkey series; do not sum them.

YACE uses the `yace` ServiceAccount and the Terraform-managed
`techx-prod-tf2-yace-cloudwatch-read` IRSA role. It has only CloudWatch metric-read actions. AWS HTTPS calls pass through the namespace egress proxy.

## Rollout order

1. Apply the production Terraform change after operator approval and record `yace_cloudwatch_role_arn`.
2. Sync chart `0.48.12` through Argo CD. Do not deploy the templates directly.
3. Wait at least one 300-second CloudWatch period.
4. Confirm YACE `/healthz`, then confirm the expected `aws_rds_*`, `aws_kafka_*`, and `aws_elasticache_*` series in Prometheus.
5. Start the AIOps runtime only after all three gate inputs for each managed service return data.

An empty result immediately after rollout is expected until the first CloudWatch window is available. A persistent empty result is not normal; check the IRSA annotation, projected token, egress-proxy access to regional STS/CloudWatch, and the configured resource dimensions.

## AIOps query mapping

The canonical queries live in `tf2-corp-platform/src/aio/config/prometheus_queries.json`.

- PostgreSQL activity: commit plus rollback rate; socket I/O: RDS receive plus transmit throughput.
- Kafka activity: partition offset rate deduplicated by topic and partition; socket I/O: broker bytes in plus bytes out.
- Valkey activity: maximum commands per second; socket I/O: maximum input plus output byte rate.

The query aliases cover both YACE's compact and snake-separated metric naming forms.

