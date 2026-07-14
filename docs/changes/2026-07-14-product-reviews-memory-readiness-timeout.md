# Change: product-reviews memory headroom and readiness timeout

## Summary

Raised `product-reviews` container memory request/limit and increased readiness gRPC probe `timeoutSeconds` from 3 to 5 so the pod is less likely to OOM or false-fail readiness under modest CPU when the shared gRPC thread pool is busy.

## Context

* Cluster Events on product-reviews (`:3551`) included:
  * readiness: `health rpc did not complete within 3s`
  * readiness/liveness: `failed to connect … within 3s/5s: context deadline exceeded`
  * readiness: `health rpc probe failed … EOF`
* Chart already used correct gRPC health on port **3551** (Tier B). Failures indicated process pressure or restarts, not a wrong probe handler.
* PER-01 already listed product-reviews as OOM-risk under tight memory; values had request **96Mi** / limit **160Mi** against P99 baseline ~80Mi with little LLM/OTEL spike room.
* Health `Check` shares the same gRPC `ThreadPoolExecutor(max_workers=10)` as long AI/DB RPCs, so a 3s readiness timeout is tight under throttle.

## Before

* `resources.requests.memory`: **96Mi**
* `resources.limits.memory`: **160Mi**
* `resources` CPU: request 60m / limit 300m (unchanged)
* readiness: grpc :3551, period 10, **timeout 3**, fail 3
* liveness: grpc :3551, period 15, timeout 5, fail 5
* `docs/operations/probe-thresholds.md` matrix: readiness timeout **3** for product-reviews

## After

* `resources.requests.memory`: **128Mi**
* `resources.limits.memory`: **256Mi**
* CPU requests/limits unchanged (60m / 300m)
* readiness: grpc :3551, period 10, **timeout 5**, fail 3 (unready window still ~30s)
* liveness unchanged
* Probe policy docs mark product-reviews as Tier B‡ (readiness timeout exception) and record the new memory floor

## Technical Design Decisions

* **Raise memory first-class with timeout** — EOF + connect failures after restarts are consistent with OOM or process death; timeout-only tuning would not stop cgroup kills.
* **Readiness timeout 5s only** — matches frontend Tier B† pattern for “same period/fail, longer single attempt”; does not lengthen the overall unready budget (`fail 3 × 10s`).
* **Do not raise liveness timeout further** — already 5s; liveness remains the slower restart path (~75s).
* **Do not change replicas/HPA or app code** — out of scope; optional follow-ups if load still saturates a single pod.
* **Rejected:** tcpSocket probes (weaker than gRPC health); readiness that checks Postgres/LLM (would NotReady on dependency blips).

## Implementation Details

1. Updated `components.product-reviews.resources` memory request/limit in `values.yaml`.
2. Set `components.product-reviews.readinessProbe.timeoutSeconds` to `5`.
3. Updated `docs/operations/probe-thresholds.md` tier footnote, matrix row, and product-reviews rationale.
4. Added this change record.

## Files Changed

**Configuration:**

* `values.yaml` — product-reviews memory 128Mi/256Mi; readiness timeout 5s.

**Documentation:**

* `docs/operations/probe-thresholds.md` — Tier B‡ note, matrix, component rationale.
* `docs/changes/2026-07-14-product-reviews-memory-readiness-timeout.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only. No platform image or infra Terraform change required.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No app code change; process has more memory headroom and readiness tolerates slower health RPCs |
| **Infrastructure** | Slightly higher memory request on spot-tolerant pool (~+32Mi request, +96Mi limit) |
| **Deployment** | Helm/Argo sync rolls product-reviews Deployment |
| **Performance** | Less cgroup OOM risk under LLM/OTEL spikes; readiness less flaky under brief RPC stalls |
| **Security** | No change |
| **Reliability** | Higher: fewer false NotReady and restart loops from tight 3s readiness / 160Mi limit |
| **Cost** | Marginal memory on Karpenter nodes |
| **Backward compatibility** | Fully compatible values upgrade |
| **Observability** | Probe Events should shift from timeout/EOF storms when root cause was memory/RPC stall |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values review | Inspect `components.product-reviews` in `values.yaml` | ✅ Applied |
| Docs matrix | Inspect `probe-thresholds.md` product-reviews row | ✅ timeout 5; memory noted |

### Manual Verification

* Not deployed in this change. Operator should sync chart and confirm pod Ready without Unhealthy storms.

### Remaining Verification (Post-Merge)

1. Argo CD sync (or helm upgrade) for the target env.
2. Confirm new resources and readiness timeout on the pod:
   ```cmd
   kubectl -n techx-corp-prod get deploy product-reviews -o yaml
   kubectl -n techx-corp-prod describe pod -l app.kubernetes.io/component=product-reviews
   kubectl -n techx-corp-prod top pod -l app.kubernetes.io/component=product-reviews
   ```
3. Watch Events for ~15 minutes under normal/load traffic; expect fewer readiness timeout/EOF events.
4. If `OOMKilled` still appears, raise limit further (e.g. 320Mi) in a follow-up; if only RPC timeouts remain under heavy Locust, consider app thread-pool or HPA separately.

## Migration or Deployment Notes

1. Sync chart via GitOps (preferred) or break-glass helm upgrade after disable auto-sync if required.
2. No secret or image tag change.
3. Rollout recreates product-reviews pods with higher memory and new readiness timeout.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Scheduling pressure from higher memory request | Low | Low | Karpenter adds capacity; reduce request if Pending |
| Looser readiness hides hung process briefly | Low | Low | Liveness still restarts after ~75s; single probe still fails after 5s |
| OOM persists above 256Mi under extreme load | Low | Medium | Raise limit again or add HPA/replicas |

**Rollback procedure:**

Revert `components.product-reviews` resources and readiness `timeoutSeconds` (and matching `probe-thresholds.md` rows) to the previous chart revision and re-sync/redeploy.

<!-- Change trail: @hungxqt - 2026-07-14 - product-reviews memory headroom and readiness timeout 5s. -->
