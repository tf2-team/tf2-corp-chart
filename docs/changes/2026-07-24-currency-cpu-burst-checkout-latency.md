# Change: Currency CPU Burst Headroom for Checkout Latency

## Summary

Raise `currency` resource limits from Guaranteed 50m/50m to Burstable 100m request / 500m limit, and raise production HPA `minReplicas` from 2 to 3, to cut multi-second `CurrencyService/Convert` tails that drive `POST /api/checkout` p95 latency.

## Context

Jaeger investigation on `techx-tf2-prod` / `techx-corp-prod` (2026-07-24) showed:

* `POST /api/checkout` p50 / p95 / p99 ≈ 228 ms / 1.7 s / 4.1 s (span metrics).
* `Currency/Convert` p50 ≈ 3.3 ms but p99 ≈ 1.4 s (healthy median, bad tail).
* Of 20 slow traces (≥500 ms), 17/20 were dominated by `oteldemo.CurrencyService/Convert` inside `prepareOrderItemsAndShippingQuoteFromCart`; 3/20 by shipping quote.
* Example slow trace: Convert USD→USD took ~2.4 s server-side while other parallel Converts on the same request finished in a few–165 ms.
* Live currency pods were Guaranteed QoS (`request = limit = 50m`). HPA stayed at 2 replicas because average CPU (~22%) and RPS stayed far below targets; latency is a tail problem averages do not see.
* Checkout was previously moved to Burstable (100m/500m) for the same throttle class of issue; currency still used 50m/50m.

## Before

**`values.yaml` (`components.currency.resources`):**

* requests: cpu 50m, memory 64Mi
* limits: cpu 50m, memory 64Mi (Guaranteed QoS)

**`values-prod.yaml` (`components.currency.autoscaling`):**

* minReplicas: 2

Observed symptom: multi-item checkout (`errgroup` parallel Convert per line item + shipping Convert) hit multi-second Convert tails; checkout p95 ~1.7 s under Locust (~10 users).

## After

**`values.yaml` (`components.currency.resources`):**

* requests: cpu 100m, memory 64Mi
* limits: cpu 500m, memory 128Mi (Burstable; burst headroom without inflating HPA CPU % as aggressively as a tiny Guaranteed limit)

**`values-prod.yaml` (`components.currency.autoscaling`):**

* minReplicas: 3

HPA CPU target (70%) and RPS target (250) unchanged.

## Technical Design Decisions

* **Prefer resource limit headroom over code changes first** — Convert logic is trivial map math; server spans prove time is spent in the currency process under concurrency, not in catalog/payment.
* **Burstable 100m/500m mirrors checkout** — same chart rationale: modest request keeps HPA utilization meaningful; higher limit avoids CFS throttle on concurrent gRPC + OTEL work.
* **Prod minReplicas 3** — HPA will not scale on average CPU/RPS while p99 is bad; a small floor gives concurrent Convert capacity immediately after sync.
* **Not changing shipping/quote in this change** — secondary (3/20 slow traces); revisit if p95 remains high after currency headroom.
* **GitOps only** — no live `kubectl set resources` / `helm upgrade` against Argo-managed release.

## Implementation Details

1. Update base currency resources in `values.yaml` and document why Guaranteed 50m/50m was removed.
2. Raise production currency HPA floor to 3 in `values-prod.yaml`.
3. Rely on Argo CD auto-sync to roll the Deployment/HPA.

## Files Changed

**Configuration:**

* `values.yaml` — Currency resources: 50m/50m Guaranteed → 100m request / 500m limit Burstable; memory limit 64Mi → 128Mi.
* `values-prod.yaml` — Currency HPA `minReplicas` 2 → 3.

**Documentation:**

* `docs/changes/2026-07-24-currency-cpu-burst-checkout-latency.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only GitOps change. No platform image rebuild and no infra Terraform change required.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Same Convert RPC contract; expected lower checkout and Convert tail latency under concurrent multi-item checkout |
| **Infrastructure** | Slightly higher currency CPU/memory budget per pod; one extra min replica in prod (2 → 3) |
| **Deployment** | Argo CD rolls currency Deployment/HPA after Git push; rolling update |
| **Performance** | Primary goal: cut Convert p99 and checkout p95 driven by throttle/queueing |
| **Security** | No change |
| **Reliability** | More headroom on money-path currency; less risk of multi-second PlaceOrder waits |
| **Cost** | Small: +1 currency pod floor in prod + higher limit (usage still expected well below 500m average) |
| **Backward compatibility** | Fully compatible |
| **Observability** | Re-check Jaeger Convert/checkout spans and HPA after sync |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values review | Manual diff of currency resources / prod minReplicas | Applied in workspace |
| Helm lint | `helm lint . -f values.yaml -f values-prod.yaml` (operator after commit) | Remaining post-merge |
| Live mutate | None (GitOps) | N/A |

### Manual Verification

* Pre-change Jaeger/Prometheus baseline recorded in investigation (checkout p95 ~1.7 s; Convert p50 ~3 ms / p99 ~1.4 s).
* Code/config change only in this workspace commit; cluster validation after Argo sync.

### Remaining Verification (Post-Merge)

1. Confirm Argo CD `techx-corp` Application Healthy/Synced.
2. `kubectl -n techx-corp-prod get deploy currency -o jsonpath` resources and `get hpa currency` minReplicas/replicas.
3. Jaeger: `currency` Convert and `frontend` `POST /api/checkout` p95/p99 under same Locust load.
4. Prometheus: currency CFS throttle ratio and checkout span histogram quantiles.

## Migration or Deployment Notes

1. Commit and push `techx-corp-chart` only.
2. Wait for Argo CD auto-sync (or sync Application if needed).
3. Expect currency rolling update and HPA desired replicas ≥ 3.
4. No secret or infra prerequisite.

```cmd
cd /d techx-corp-chart
helm lint . -f values.yaml -f values-prod.yaml
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Currency pods pending due to higher request | Low | Medium | Cluster has headroom historically; reduce request to 50m keep 500m limit if needed |
| HPA still does not scale on latency | Medium | Low | minReplicas 3 provides floor; latency-based HPA is a follow-up if needed |
| Cost increase from +1 pod | Low | Low | Acceptable for money-path SLO |

**Rollback procedure:**

1. Revert this commit in `techx-corp-chart` (restore 50m/50m and prod `minReplicas: 2`).
2. Push; Argo CD reconciles previous resources/HPA.

<!-- Change trail: @hungxqt - 2026-07-24 - Document currency CPU burst fix for checkout Convert latency. -->
