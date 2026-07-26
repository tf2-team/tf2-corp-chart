# Change: OpenSearch startup probe budget and CPU for cold start

## Summary

Raises OpenSearch Guaranteed CPU from 100m to 500m and extends the startup probe failure threshold from 36 to 60 so the pod can bind `:9200` after JVM bootstrap and index recovery without being SIGTERM-killed by kubelet.

## Context

After EBS encrypt-migrate of `opensearch-data-opensearch-0`, the pod attached the encrypted volume and recovered 11 indices, but startup probe failed with `dial tcp …:9200: connect: connection refused`. Logs showed HTTP bind only after ~6.5 minutes on 100m CPU — equal to the previous probe budget (30s + 36×10s), so kubelet killed the container (exit 143) in a restart loop.

## Before

* `components.opensearch.resources`: cpu request/limit **100m**, memory 960Mi Guaranteed.
* `startupProbe.failureThreshold`: **36** (~6.5 minutes).
* Live: restart loop; bind `:9200` then immediate kill.

## After

* CPU request/limit **500m** (memory unchanged 960Mi Guaranteed).
* `startupProbe.failureThreshold`: **60** (~10.5 minutes).
* Faster bootstrap + longer budget so cold start / post-PVC recovery can pass probes.

## Technical Design Decisions

* Keep Guaranteed QoS (request = limit) for search stability.
* Prefer higher CPU over only lengthening probes so steady-state latency also improves under load.
* Extended failureThreshold is a safety margin if the node is contended; not a substitute for adequate CPU.

## Implementation Details

1. Updated `values.yaml` OpenSearch `resources.requests/limits.cpu` to `500m`.
2. Updated `startupProbe.failureThreshold` to `60` and refreshed cold-start comments.
3. Argo CD auto-sync on `main` applies the StatefulSet template change (rolling/recreate per chart rollout).

## Files Changed

* `values.yaml` — OpenSearch CPU and startup probe.
* `docs/changes/2026-07-22-opensearch-startup-probe-cpu.md` — this record.

## Dependencies and Cross-Repository Impact

None. Relies on existing encrypted PVC `opensearch-data-opensearch-0` / `gp3-encrypted`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | OpenSearch should become Ready without restart loop after sync |
| **Infrastructure** | +400m CPU request on critical MNG for the OpenSearch pod |
| **Deployment** | Argo sync; STS template update |
| **Performance** | Faster cold start; better headroom under log ingest |
| **Cost** | Small CPU increase on one Guaranteed pod |
| **Backward compatibility** | Fully backward-compatible |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Pending post-edit |

### Manual Verification

* Post-sync: `kubectl get pod opensearch-0 -n techx-corp-prod` → Ready 1/1.
* Logs show `publish_address …:9200` and `started` without immediate `stopping`.

### Remaining Verification (Post-Merge)

* Operator: confirm Argo Healthy; optional OpenSearch `_cluster/health` if clients use HTTPS/demo certs.

## Migration or Deployment Notes

1. Merge/push chart to `main` (prod Argo `targetRevision: main`).
2. Wait for Argo to update OpenSearch STS/pod.
3. Expect a few minutes of startup probe refused events until first successful TCP probe.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Critical node CPU pressure | Low | Medium | 500m is still modest; Karpenter/MNG capacity |
| Probe still too short | Low | Medium | Raise failureThreshold further or CPU |

**Rollback procedure:** Revert `values.yaml` CPU to 100m and failureThreshold to 36 via Git; Argo sync.

<!-- Change trail: @hungxqt - 2026-07-22 - OpenSearch CPU 500m and startup probe failureThreshold 60. -->
