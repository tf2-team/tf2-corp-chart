# Change: Kafka startup probe to stop mid-bootstrap restarts

## Summary

Kafka was emitting repeated `connection refused` on readiness and liveness while the JVM/KRaft broker was still binding port 9092. Without a `startupProbe`, liveness counted those failures and could restart the container mid-boot. This change adds a long TCP startup probe (same pattern as OpenSearch) and softens post-ready readiness to the standard 3-failure window.

## Context

* Live symptom: `Readiness probe failed: dial tcp …:9092: connect: connection refused` and matching liveness failures.
* Chart previously used Tier C readiness (fail 9 ≈ 90s) and liveness (period 30, fail 5 ≈ 150s) **without** startup gating.
* Kafka image runs Apache Kafka 3.9 KRaft with OTEL Java agent under Guaranteed 200m CPU / 700Mi — cold bind of :9092 can exceed a couple of minutes.
* Related pattern: `docs/changes/2026-07-10-opensearch-startup-probe-memory-lock.md`.

## Before

```yaml
readinessProbe:
  tcpSocket: { port: 9092 }
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 9
livenessProbe:
  tcpSocket: { port: 9092 }
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 5
# no startupProbe
```

Liveness and readiness both ran from container start; connection refused during bootstrap counted toward liveness kill.

## After

```yaml
startupProbe:
  tcpSocket: { port: 9092 }
  initialDelaySeconds: 20
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 36  # ~6.2m (20s + 36*10s)
readinessProbe:
  tcpSocket: { port: 9092 }
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
livenessProbe:
  tcpSocket: { port: 9092 }
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 5  # only after startup succeeds
```

## Technical Design Decisions

* Prefer **startupProbe** over only raising liveness `initialDelaySeconds` so post-ready hangs are still detected promptly.
* Keep **TCP :9092** (matches compose `nc -z`); no exec dependency on kafka CLI paths.
* Align failure budget with OpenSearch-class multi-minute JVM boots rather than compose’s shorter `start_period` (optimistic for local Docker).
* Early Unhealthy Events for connection refused remain **expected** until the first successful startup probe.

## Implementation Details

1. Added `components.kafka.startupProbe` in `values.yaml`.
2. Set readiness `failureThreshold: 3` after startup (traffic gate once port is up).
3. Left liveness timings unchanged but they no longer run until startup succeeds.
4. Updated `docs/operations/probe-thresholds.md` kafka section and matrix.

## Files Changed

**Configuration:**

* `values.yaml` — Kafka `startupProbe`; readiness fail threshold 3 after startup.

**Documentation:**

* `docs/operations/probe-thresholds.md` — Kafka startup rationale and matrix.
* `docs/changes/2026-07-11-kafka-startup-probe.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only. Dependent services already wait for Kafka via initContainers where needed.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No app code change; Kafka pod less likely to CrashLoop during cold start |
| **Infrastructure** | No change |
| **Deployment** | Helm/Argo sync applies new probes; may show Unhealthy Events for first minutes of boot |
| **Reliability** | Higher: liveness no longer kills mid-bootstrap |
| **Backward compatibility** | Fully compatible chart upgrade |
| **Observability** | Startup Unhealthy Events expected until :9092 binds |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Lint | `helm lint .` | ✅ Pass |
| Template | `helm template` assert kafka startupProbe | ✅ Pass |

### Manual Verification

* Pre-fix Events matched connection refused on readiness + liveness without startup.
* Post-merge: pod should reach Ready without liveness restarts during first ~minutes of boot.

### Remaining Verification (Post-Merge)

* After sync: `kubectl describe pod -l app.kubernetes.io/component=kafka` — confirm startupProbe present; no `Killing` from liveness until long after start unless process truly hung.
* If startup still exceeds ~6 minutes under extreme throttle, raise `startupProbe.failureThreshold` or Kafka CPU request.

## Migration or Deployment Notes

1. Sync/upgrade chart with new `values.yaml`.
2. If the pod is already CrashLooping, delete the pod after sync so it restarts with the new probe set:
   `kubectl delete pod -n <ns> -l app.kubernetes.io/component=kafka`
3. Early Unhealthy connection refused for the first minutes can still appear and are normal until :9092 listens.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Startup still exceeds ~6.2 minutes | Low | Medium | Raise failureThreshold or CPU |
| Process hung after Ready | Low | Medium | Liveness still restarts after 5×30s failures |

**Rollback procedure:**

Revert `components.kafka` probe block in `values.yaml` to the previous revision and redeploy.
