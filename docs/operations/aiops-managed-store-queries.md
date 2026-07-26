# AIOps RCA query pack — managed data stores (valkey-cart, postgresql, kafka)

Production PostgreSQL, Valkey, and Kafka are AWS managed services (Directive-08). They have no pods, so pod-scoped `request_rate` / `cpu` / `socket_io` queries return nothing and the RCA detector reports `missing_metrics`. This doc is the replacement query set, ready to register in the RCA tool's `config/queries/*.yaml`. Mark the three topology nodes `kind: managed-store` so the detector uses these instead of the pod template.

## Critical PromQL rules for these series

1. **Per-agent duplication.** The `kafkametrics`, `redis/valkey-cart`, and `postgresql/rds` receivers run on every OTel DaemonSet agent (one per node, ~17), so each engine metric exists once per node. Always collapse with `max(...)` or `avg(...)` — a bare `sum(...)` over-counts by the node count.
2. **CloudWatch series (YACE)** (`aws_rds_*`, `aws_elasticache_*`, `aws_kafka_*`) are scraped once via annotation discovery (node-pinned) — no duplication. Select them by metric name + `dimension_*` labels, never by `job`.
3. CloudWatch values arrive with ~300 s granularity and a few minutes' delay; treat them as slow-moving saturation signals, not sub-minute anomaly inputs.

## valkey-cart (ElastiCache `techx-prod-tf2-cart`)

| Signal | PromQL |
|---|---|
| request_rate (commands/s) | `max(redis_commands_per_second)` |
| cpu (engine, by state) | `sum by (state) (max by (state) (rate(redis_cpu_time_seconds_total[5m])))` |
| cpu (host %, after YACE) | `max(aws_elasticache_engine_cpuutilization_average)` |
| socket_io (bytes/s) | `max(rate(redis_net_input_bytes_total[5m])) + max(rate(redis_net_output_bytes_total[5m]))` |
| connections | `max(redis_clients_connected)` |
| memory pressure | `max(redis_memory_used_bytes)` or `max(aws_elasticache_database_memory_usage_percentage_average)` |

## postgresql (RDS `techx-prod-tf2-postgresql`)

| Signal | PromQL |
|---|---|
| request_rate (tx/s) | `max(rate(postgresql_commits[5m])) + max(rate(postgresql_rollbacks[5m]))` |
| backends (design-doc SLI) | `max by (postgresql_database_name) (postgresql_backends)` |
| cpu (after YACE) | `max(aws_rds_cpuutilization_average{dimension_DBInstanceIdentifier="techx-prod-tf2-postgresql"})` |
| socket_io (bytes/s, after YACE) | `max(aws_rds_network_receive_throughput_average) + max(aws_rds_network_transmit_throughput_average)` |
| connections (after YACE) | `max(aws_rds_database_connections_average)` |
| disk / IOPS (after YACE) | `aws_rds_free_storage_space_average`, `aws_rds_read_iops_average`, `aws_rds_write_iops_average` |

## kafka (MSK `techx-prod-tf2-msk`)

| Signal | PromQL |
|---|---|
| request_rate (messages/s in) | `sum(max by (topic, partition) (rate(kafka_partition_current_offset[5m])))` — TBC: confirm the exact offset metric name against `/api/v1/label/__name__/values` (`kafka_.*`) after deploy |
| consumer lag | `max by (group, topic) (kafka_consumer_group_lag)` (TBC name) |
| cpu (after YACE) | `avg(max by (dimension_Broker_ID) (aws_kafka_cpu_user_average + aws_kafka_cpu_system_average))` |
| socket_io (bytes/s, after YACE) | `sum(max by (dimension_Broker_ID) (aws_kafka_bytes_in_per_sec_average + aws_kafka_bytes_out_per_sec_average))` |
| disk (after YACE) | `max by (dimension_Broker_ID) (aws_kafka_kafka_data_logs_disk_used_average)` |

## Availability matrix

| Metric class | valkey-cart | postgresql | kafka |
|---|---|---|---|
| Engine metrics (OTel receiver) | `redis_*` (live) | `postgresql_*` (after receiver change) | `kafka_*` (live) |
| Host CPU/network (YACE) | `aws_elasticache_*` | `aws_rds_*` | `aws_kafka_*` |

`TBC` entries must be confirmed once against the live label values and this doc updated.

## Operational notes for the RCA tool

- The Prometheus 9090 ingress NetworkPolicy admits only grafana, jaeger, prometheus-adapter, and otel-collector pods. When the AIOps runtime deploys in-cluster, its pod selector must be added to `templates/networkpolicy.yaml` (`allow-to-prometheus`) or every query fails regardless of series existence.
- Missing data must never be read as healthy (AIOps design rule): if these series disappear again, suspect the receiver config (collector agent logs) or overlay/values array desync — see `docs/changes/2026-07-26-managed-store-metrics-receivers.md`.

<!-- Change trail: @hungxqt - 2026-07-26 - Initial managed-store RCA query pack. -->
