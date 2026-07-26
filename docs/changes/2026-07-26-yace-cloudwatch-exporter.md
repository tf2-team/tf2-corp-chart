# Change: YACE CloudWatch exporter component for managed-store host metrics

## Summary

Adds `components.yace` — the prometheus-community yet-another-cloudwatch-exporter (YACE) — to production so CloudWatch host metrics of the Directive-08 managed data stores (RDS `techx-prod-tf2-postgresql`, ElastiCache `techx-prod-tf2-cart`, MSK `techx-prod-tf2-msk`) become `aws_rds_*` / `aws_elasticache_*` / `aws_kafka_*` series in the in-cluster Prometheus. This supplies the CPU and network signals the AIOps RCA detector cannot get from engine-level metrics (see `docs/changes/2026-07-26-managed-store-metrics-receivers.md` and `docs/operations/aiops-managed-store-queries.md`). Authentication is IRSA (role from `techx-corp-infra` module `cloudwatch-exporter`), the CloudWatch/STS APIs are reached only through the egress-proxy allowlist, and the OTel DaemonSet agent scrapes the pod via annotation discovery.

## Context

Managed services have no pods, so host CPU/network exists only in CloudWatch. The RCA detector requires them as Prometheus series. The egress-proxy allowlist already contained `monitoring.us-east-1.amazonaws.com:443` and `sts.us-east-1.amazonaws.com:443` (Grafana CloudWatch datasource), so no allowlist change was needed.

## Before

No CloudWatch exporter existed. `aws_*` metric series were absent from Prometheus; RDS/MSK CPU and network utilization were visible only in the AWS console/Grafana CloudWatch datasource, not to PromQL consumers.

## After

- `components.yace` (prod-enabled, base-disabled) renders a 1-replica Deployment, Service, dedicated `yace` ServiceAccount (`automountServiceAccountToken: false`, IRSA annotation `arn:aws:iam::493499579600:role/techx-prod-tf2-yace-cloudwatch-read`), ConfigMap `yace-config`, and NetworkPolicy `yace`.
- Image: `quay.io/prometheuscommunity/yet-another-cloudwatch-exporter` `v0.67.0` pinned by digest `sha256:404791bf…` (public digest-pinned image, matching busybox/envoy precedent; ECR mirror + cosign signing is a follow-up required before policy-controller namespace opt-in).
- Command overrides `--listen-address=:5000` (upstream default binds loopback only, which would break scraping) and `--config.file=/etc/yace/config.yml`.
- Static jobs (fixed dimension tuples, 300 s period, Average): AWS/RDS (`techx-prod-tf2-postgresql`), AWS/ElastiCache (`techx-prod-tf2-cart-001/-002`), AWS/Kafka (brokers 1–2 of `techx-prod-tf2-msk`).
- Scrape path: pod annotations `io.opentelemetry.discovery.metrics/*` with scraper `prometheus_simple` (60 s). The collector's k8s observer is node-pinned in daemonset mode, so exactly one agent scrapes the pod — no per-node duplication.
- NetworkPolicy: ingress 5000 from otel-collector pods only; egress only to egress-proxy:10000 (plus namespace-wide DNS policy). No direct internet or Kubernetes API access.
- `yace` added to `egressProxy.callers` (base + prod; prod list replaces base) → automatic `HTTPS_PROXY`/`NO_PROXY` env injection and egress-proxy ingress admission. `AWS_STS_REGIONAL_ENDPOINTS=regional` keeps STS on the allowlisted regional endpoint.
- `yace` added to the mandate-17 first-party identity inventory.

## Technical Design Decisions

- **Component-map deployment** (vs standalone template or upstream YACE chart): reuses SA/IRSA, imageOverride+digest, mountedConfigMaps, proxy-env injection, and hardened default securityContext; no Chart.lock churn; pods get the `opentelemetry.io/name` labels all NetworkPolicy selectors rely on.
- **Static jobs, no tag discovery**: instance names are Terraform-fixed; omitting `tag:GetResources` keeps IAM read-only-metrics-only and avoids adding `tagging.us-east-1.amazonaws.com` to the proxy allowlist. Trade-off: broker/replica scale-out requires updating the config dimensions here.
- **300 s CloudWatch period**: matches standard-resolution granularity; ≈ 38 metric queries per cycle ≈ 11 k GetMetricData/day ≈ $3–4/month. The 60 s pod scrape re-reads cached values at no API cost.
- **YAML anchors inside `config.yml`**: the ConfigMap payload is a literal block scalar; the anchors resolve in YACE's own YAML parser, not Helm's.
- **Known caveat**: exported series select by metric name + `dimension_*` labels (the OTLP path rewrites `job`); documented in the query pack.

## Implementation Details

1. `values.schema.json`: `definitions.Components.properties.yace` added (`$ref` Component). Components is `additionalProperties: false`, so the key is mandatory for lint.
2. `values.yaml`: `egressProxy.callers` + `yace`; disabled base stub `components.yace` (`useDefault.env: false` — no OTel demo env needed).
3. `values-prod.yaml`: prod `egressProxy.callers` + `yace`; full `components.yace` block (SA/IRSA, image digest, command, port 5000, env, discovery annotations, securityContext 65534, resources 25m/64Mi–200m/256Mi, `/healthz` probes, `mountedConfigMaps` with the static-jobs config).
4. `templates/networkpolicy.yaml`: section "31. YACE" — ingress from otel-collector on 5000; `$enforceEgress`-gated egress to egress-proxy only. No `0.0.0.0/0`, no API-server CIDR (mandate-17 CI assertions unaffected).
5. `scripts/mandate17-inventory.ps1`: `yace` appended to `$firstParty`.
6. `Chart.yaml`: 0.48.11 → 0.48.12 (no dependency change).

## Files Changed

**Configuration:**
* `values.yaml` — egressProxy caller + disabled `components.yace` stub.
* `values-prod.yaml` — egressProxy caller + full `components.yace` (image, IRSA, config, probes).
* `values.schema.json` — `yace` Component entry. *(Change trail exception for `values.schema.json`: JSON cannot contain comments.)*
* `Chart.yaml` — version bump 0.48.12.

**Templates:**
* `templates/networkpolicy.yaml` — NetworkPolicy `yace` (section 31).

**Scripts:**
* `scripts/mandate17-inventory.ps1` — `yace` in first-party inventory.

**Documentation:**
* `docs/changes/2026-07-26-yace-cloudwatch-exporter.md` — this change record.

## Dependencies and Cross-Repository Impact

* Requires `techx-corp-infra` change `docs/changes/2026-07-26-yace-cloudwatch-read-irsa.md` **applied first** (`terraform apply` creating role `techx-prod-tf2-yace-cloudwatch-read`); until then the pod runs but CloudWatch calls fail AccessDenied.
* Related: `docs/changes/2026-07-26-managed-store-metrics-receivers.md` (engine-level metrics half of the same RCA gap).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None; storefront untouched. |
| **Infrastructure** | Consumes the new IAM role; no cluster capacity change (25m/64Mi request). |
| **Deployment** | Argo CD auto-sync creates Deployment/Service/SA/ConfigMap/NetworkPolicy. |
| **Performance** | Negligible; single small pod. |
| **Security** | Read-only CloudWatch via IRSA; egress via allowlisted proxy only; non-root digest-pinned image; no K8s API token. |
| **Reliability** | Metrics-only workload; failure degrades to missing `aws_*` series. |
| **Cost** | ≈ $3–4/month GetMetricData. |
| **Backward compatibility** | Fully additive. |
| **Observability** | Adds `aws_rds_*`, `aws_elasticache_*`, `aws_kafka_*` series for RCA cpu/socket_io signals. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Dependency build | `helm dependency build .` | ✅ Pass |
| Lint + schema | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | ✅ Pass |
| Rendered manifests (CI gate) | `pwsh ./tests/mandate17/verify-rendered-manifests.ps1` | ✅ Pass |
| Identity inventory | `pwsh ./scripts/mandate17-inventory.ps1` | ✅ Pass (yace included) |

### Manual Verification

* Rendered yace Deployment shows digest-pinned image, `HTTPS_PROXY` env injection, SA annotation, discovery annotations, and the config mount; NetworkPolicy `yace` present; egress-proxy ingress selector includes `yace`.
* CloudWatch dimension tuples pre-verified read-only with `aws cloudwatch list-metrics` (RDS DBInstanceIdentifier; ElastiCache CacheClusterId `techx-prod-tf2-cart-001/-002` + CacheNodeId `0001`; Kafka "Cluster Name"/"Broker ID" 1–2) — static jobs fail silently on wrong tuples.

### Remaining Verification (Post-Merge)

* Operator: after Argo sync, `kubectl -n techx-corp-prod logs deploy/yace` (no AccessDenied/CONNECT errors), then Prometheus `count by (__name__)({__name__=~"aws_(rds|elasticache|kafka)_.*"})`.
* Update `docs/operations/aiops-managed-store-queries.md` TBC entries with confirmed metric names.

## Migration or Deployment Notes

1. Apply the infra IRSA change first (`terraform apply` in `techx-corp-infra/environments/production`).
2. Merge this chart change; Argo CD auto-syncs.
3. Post-sync checks per above.
4. If ElastiCache replica count or MSK broker count changes in Terraform, update the static job dimensions in `values-prod.yaml`.
5. Follow-up before policy-controller prod namespace opt-in: mirror the image to ECR `techx-prod-corp/yace`, cosign-sign/attest, and flip `imageOverride.repository`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Wrong dimension tuple → silent empty job | Medium | Low | Tuples pre-verified via list-metrics; post-merge series count check |
| `/healthz` absent in pinned version → probe crashloop | Low | Medium | Verified against upstream v0.67 docs; fallback: switch probes to `tcpSocket: 5000` |
| IRSA role missing at sync time | Low | Low | Ordering note above; pod degrades to AccessDenied logs only |
| MSK metric names vary with monitoring level | Medium | Low | Add/swap per `aws cloudwatch list-metrics --namespace AWS/Kafka` results |

**Rollback procedure:**

`git revert` this commit and merge; Argo CD prunes the yace Deployment/Service/SA/ConfigMap/NetworkPolicy (`prune: true`). The infra role remains but is inert (its own change doc covers reverting it).

<!-- Change trail: @hungxqt - 2026-07-26 - Record yace CloudWatch exporter component addition. -->
