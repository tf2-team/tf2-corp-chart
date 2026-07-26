# Change: Raise frontend-proxy memory after OOMKilled 503 outage

## Summary

Raised Envoy `frontend-proxy` Guaranteed resources from `30m/48Mi` to `50m/128Mi` so the edge proxy stops `OOMKilled` CrashLoopBackOff and the internal ALB regains healthy targets for `https://internal.hungtran.id.vn` (and CloudFront storefront origin).

## Context

Live prod investigation (2026-07-23) for `https://internal.hungtran.id.vn` (all subpaths) returning **503**:

* HTTP `Server: awselb/2.0` — ALB has no healthy targets
* Same 503 on `https://shop.hungtran.id.vn` via CloudFront (`X-Cache: Error from cloudfront`) — shared internal ALB origin
* Namespace `techx-corp-prod`: `deployment/frontend-proxy` **0/2 Available**
* Pods in `CrashLoopBackOff`; last state **`OOMKilled`**, exit **137**
* Limits/requests: **cpu 30m / memory 48Mi** (Guaranteed)
* Envoy starts admin + clusters, then cgroup kill within ~30s of start
* Endpoints: only intermittent Ready addresses; ALB target group effectively empty

Historical PER-01 sizing used P99 ~30.20Mi RSS; production route set (admin paths, OTEL tracer, load-generator traffic) exceeds 48Mi.

* Related: `docs/adr/PER-01-resource-right-sizing.md`
* Related: `docs/changes/2026-07-16-jaeger-oom-raise-memory.md`

## Before

```yaml
components:
  frontend-proxy:
    resources:
      requests:
        cpu: 30m
        memory: 48Mi
      limits:
        cpu: 30m
        memory: 48Mi
```

## After

```yaml
components:
  frontend-proxy:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 50m
        memory: 128Mi
```

Public ALB ingress annotations, replicas/HPA floors, and probe paths are unchanged.

## Technical Design Decisions

* **Memory 48Mi → 128Mi (request = limit)** — confirmed root cause is cgroup OOM, not DNS/VPN/ACM/config. Keeps Guaranteed QoS for the critical edge path.
* **CPU 30m → 50m (request = limit)** — modest headroom so HPA CPU (70%) and Envoy under load are less throttled during restarts; not the primary failure mode.
* **Base `values.yaml` (not prod-only)** — same Guaranteed budget for all envs; avoids reintroducing undersizing in dev.
* **Deferred:** further raise if RSS approaches 128Mi under peak load; digests/image change not required for this incident.

## Implementation Details

1. Updated `components.frontend-proxy.resources` in base `values.yaml`.
2. Updated PER-01 ADR line for frontend-proxy to match live sizing.
3. Recorded this change document.

## Files Changed

**Configuration:**

* `values.yaml` — frontend-proxy Guaranteed CPU/memory raise.

**Documentation:**

* `docs/adr/PER-01-resource-right-sizing.md` — frontend-proxy resource line aligned with fix.
* `docs/changes/2026-07-23-frontend-proxy-oom-raise-memory.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Image digests, platform code, and infra modules are unchanged. Argo CD app `techx-corp` reconciles chart values after merge/push.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Edge proxy stays Ready; storefront + operator private DNS paths serve again (no app logic change) |
| **Infrastructure** | +~160Mi request budget for 2 min replicas on Critical MNG (was 96Mi total) |
| **Deployment** | GitOps sync rolls Deployment; ALB targets re-register when pods Ready |
| **Performance** | Removes CrashLoop restart churn; slight more CPU headroom for Envoy |
| **Reliability** | Restores ALB healthy targets; ends cluster-wide 503 on proxy-backed hosts |
| **Cost** | Negligible on dual critical nodes |
| **Backward compatibility** | Fully compatible |
| **Observability** | Proxy up again for `/grafana/`, `/jaeger/`, etc. via internal hostname |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| YAML structure | Manual edit review of `values.yaml` resources block | ✅ |
| Cluster pre-fix state | `kubectl get deploy frontend-proxy -n techx-corp-prod` → 0/2; OOMKilled | ✅ Confirmed root cause |

### Manual Verification

* Pre-fix: `curl -i https://internal.hungtran.id.vn/grafana/` → 503 `awselb/2.0`
* Pre-fix: both frontend-proxy pods `OOMKilled` / `CrashLoopBackOff`

### Remaining Verification (Post-Merge)

After Argo CD syncs `techx-corp`:

```cmd
kubectl get pods -n techx-corp-prod -l app.kubernetes.io/name=frontend-proxy
kubectl describe pod -n techx-corp-prod -l app.kubernetes.io/name=frontend-proxy
curl -i https://internal.hungtran.id.vn/
curl -i https://internal.hungtran.id.vn/grafana/
curl -i https://shop.hungtran.id.vn/
```

Expect: pods Ready 1/1, no OOMKilled lastState, HTTP 200/302 (not ALB 503).

## Migration or Deployment Notes

1. Commit and push this chart change to the GitOps source of truth for production.
2. Wait for Argo CD `techx-corp` Application to sync (auto-sync).
3. Confirm Deployment rolls with new resources (`memory: 128Mi`).
4. Do **not** `helm upgrade` or `kubectl set resources` against the Argo-managed release.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Still OOM at 128Mi under extreme load | Low | High | Raise further (e.g. 192–256Mi) via chart; check Envoy heap |
| Critical MNG packing pressure | Low | Medium | Free capacity or scale Critical MNG if pods Pending |
| Argo delay before recovery | Medium | Medium | Monitor Application sync/health after push |

**Rollback procedure:**

Revert `components.frontend-proxy.resources` in `values.yaml` to `30m/48Mi` and push; Argo resyncs. Not recommended while OOM root cause remains.

<!-- Change trail: @hungxqt - 2026-07-23 - Document frontend-proxy OOM raise after internal/shop 503 outage. -->
