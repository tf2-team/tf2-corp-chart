# Change: REL-06 standardize resource requests/limits

## Context

Most microservices in `techx-corp-chart` defined only memory `limits` (often as low as `20Mi`) without CPU/memory `requests`. That weakens scheduling accuracy and risks `OOMKilled` under light-to-moderate load. This change ports the REL-06 solution from [tf2-corp-chart PR #11](https://github.com/tmcmanhcuong/tf2-corp-chart/pull/11).

## Before

* Many components had `limits.memory` only.
* Several services used under-provisioned memory limits (`20Mi`), including `checkout`, `currency`, `shipping`, `product-catalog`, and `valkey-cart`.
* Go-based services used low `GOMEMLIMIT` values (`16MiB` / `60MiB`) aligned to those tight limits.
* Stateful components (`kafka`, `postgresql`, `valkey-cart`, `opensearch`) did not set Guaranteed QoS (`requests == limits`).

## After

* All primary microservice and observability workloads define both `requests` and `limits` for CPU and memory.
* Stateless services use Burstable QoS (`request < limit`).
* Stateful/data services use Guaranteed QoS (`request == limit`).
* No primary microservice memory limit remains below `64Mi`.
* `GOMEMLIMIT` raised to `100MiB` for `checkout`, `product-catalog`, and `flagd`.
* Grafana main memory limit kept at the local `512Mi` value (higher than PR baseline `300Mi`) while adding CPU/memory requests and a CPU limit.

## Implementation

* Updated `values.yaml` resource blocks for app components, flagd UI sidecar, and subchart-related resources (`opentelemetry-collector`, `jaeger`, `prometheus`, `grafana`, `opensearch`).
* Added backlog documentation describing QoS standards and acceptance criteria.
* Left init containers, `llm` (still without resources in values), and `metrics-server` CPU limit unchanged, matching the source PR scope.

## Files Changed

* `values.yaml`
  * Added/standardized `resources.requests` and `resources.limits`; raised under-provisioned memory limits; updated `GOMEMLIMIT` for Go services.
* `docs/backlogs/2026-07-10-rel-06-resource-requests-limits.md`
  * Added REL-06 backlog (ported from PR #11, paths adapted for this chart).
* `docs/changes/2026-07-10-rel-06-resource-requests-limits.md`
  * This change record.

## Impact

* **Application behavior:** Safer headroom against OOM under load; Go runtimes can use more memory before GC pressure.
* **Scheduling / reliability:** Scheduler receives explicit CPU/memory requests; stateful services become Guaranteed QoS and less likely to be evicted.
* **Cost / capacity:** Higher aggregate requests may make pods harder to schedule on small node pools if capacity is tight.
* **Backward compatibility:** Values-only change; no API or template schema change. Existing overrides in env-specific values files still take precedence when set.

## Validation

* `helm lint .` — passed (icon warning only).
* `helm template rel06 . --namespace techx-corp` — rendered successfully.
* Parsed rendered workloads: primary app containers expose both requests and limits; no container memory limit below `64Mi` for microservices covered by this change.

## Migration or Deployment Notes

None required beyond a normal chart deploy/upgrade (for example Argo CD sync or `helm upgrade`). After deploy, watch node allocatable capacity and pod `Pending` events for insufficient CPU/memory.

## Risks and Rollback

* **Risk:** Increased requests may exceed node capacity and leave pods `Pending`.
* **Rollback:** Revert `values.yaml` resource blocks to the previous revision and re-deploy/upgrade the chart.
