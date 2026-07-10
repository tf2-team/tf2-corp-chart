# Change: OpenSearch startup probe and disable memory lock

## Summary

OpenSearch was stuck in a restart loop because cold start often exceeds one minute before port 9200 binds, and the liveness probe killed the container mid-bootstrap. This change adds a long `startupProbe`, softens readiness/liveness, and sets `bootstrap.memory_lock=false` for Kubernetes (no memlock ulimit / `IPC_LOCK`).

## Context

* Pod events showed repeated `Readiness probe failed: dial tcp …:9200: connect: connection refused` and `Container opensearch failed liveness probe, will be restarted`.
* Container logs showed a healthy early bootstrap (plugins load, node identity, security plugin disabled as configured) but no HTTP bind before the process was restarted.
* Compose sets `ulimits.memlock` with `bootstrap.memory_lock=true`; the chart dropped all capabilities and never set memlock, so locking is not viable on EKS.

## Before

* `readinessProbe`: TCP 9200, `initialDelaySeconds: 30`, `periodSeconds: 10`.
* `livenessProbe`: TCP 9200, `initialDelaySeconds: 60`, `periodSeconds: 20`.
* No `startupProbe`.
* `bootstrap.memory_lock=true`.

## After

* `startupProbe`: TCP 9200, period 10s, failureThreshold 30 (~5 minutes) before first successful listen.
* `readinessProbe` / `livenessProbe`: no aggressive initial delay; liveness period 30s, failureThreshold 5 (after startup succeeds).
* `bootstrap.memory_lock=false`.

## Technical Design Decisions

* Prefer `startupProbe` over a very large liveness `initialDelaySeconds` so post-ready failures are still detected promptly.
* Disable memory lock rather than adding `IPC_LOCK` and host ulimits; demo/single-node does not need mlock, and node-level swap disable is the usual K8s approach.
* Keep existing CPU/memory limits (200m / 1100Mi) and heap (`-Xms400m -Xmx400m`); probe fix is sufficient if bootstrap completes within five minutes.

## Implementation Details

1. Updated `components.opensearch` probes in `values.yaml`.
2. Set `bootstrap.memory_lock` env to `"false"` with an inline comment explaining the K8s constraint.

## Files Changed

**Configuration:**

* `values.yaml` — OpenSearch `startupProbe`, readiness/liveness timing, `bootstrap.memory_lock=false`.

**Documentation:**

* `docs/changes/2026-07-10-opensearch-startup-probe-memory-lock.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Platform image and compose settings are unchanged; only Helm component defaults for the cluster deployment.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | OpenSearch allowed up to ~5 minutes to bind 9200 before being killed; fewer false restarts during cold start |
| **Infrastructure** | No change |
| **Deployment** | Helm upgrade / Argo CD sync of chart values only |
| **Performance** | No intentional change; avoids restart thrash that previously wasted CPU |
| **Security** | No change (security plugin remains disabled for demo) |
| **Reliability** | Higher chance of stable Ready state on first boot |
| **Cost** | None |
| **Backward compatibility** | Fully compatible; env overlays do not override these fields |
| **Observability** | OpenSearch log pipeline more likely to become available |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values review | Manual inspect of `components.opensearch` block | ✅ Applied |

### Manual Verification

* Prior cluster: logs showed mid-bootstrap without `:9200` bind under 60s liveness — consistent with this fix.
* Post-merge: confirm pod reaches Ready and logs show HTTP publish / node started without `Killing` from liveness during boot.

### Remaining Verification (Post-Merge)

1. Sync / upgrade chart to cluster.
2. `kubectl get pod -l app.kubernetes.io/component=opensearch -w` (or equivalent labels) until Ready.
3. `kubectl logs opensearch-0 -c opensearch` — expect bind on 9200 without restart loop.
4. Optional: `kubectl exec` / curl `http://opensearch:9200/_cluster/health`.

## Migration or Deployment Notes

1. Deploy chart revision that includes this `values.yaml` change (Argo CD auto-sync or `helm upgrade`).
2. If the pod is already CrashLooping, delete the pod after sync so it restarts with new probes:  
   `kubectl delete pod opensearch-0` (StatefulSet will recreate).
3. No data migration (emptyDir data path).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Startup still exceeds 5 minutes (extreme resource starvation) | Low | Medium | Increase `startupProbe.failureThreshold` or CPU request |
| Process truly hung after Ready | Low | Medium | Liveness still restarts after 5 consecutive failures |

**Rollback procedure:**

Revert `components.opensearch` probes and `bootstrap.memory_lock` in `values.yaml` to the previous values and redeploy the chart revision.
