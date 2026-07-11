# Change: Fix OTel Collector Agent Health Probe Restart Storm

## Summary

Stabilized the `otel-collector-agent` DaemonSet on packed Critical MNG nodes by raising memory/CPU limits, adding a long `startupProbe`, relaxing readiness/liveness timeouts, disabling hostmetrics (which contributed to D-state under pressure), and lowering collector self-telemetry from `detailed` to `basic`. Combined with Critical MNG capacity relief (load-generator scaled down), this stops `connection refused` on `:13133` from becoming a restart storm.

## Context

Pod on Critical MNG node `ip-10-1-10-52` (`t4g.medium`, ~96% memory) repeatedly failed:

```text
Readiness/Liveness probe failed: dial tcp <podIP>:13133: connect: connection refused
```

Findings:

* Three other agents (other nodes) were `1/1 Ready` with the same config.
* Working set of healthy agents ~110–150Mi against a **200Mi** limit (`GOMEMLIMIT=160MiB`).
* Node memory limits overcommitted (~218%); node working set ~96%.
* Sibling agent on the other critical node previously exited **137** (OOM).
* Debug pod with same image/config **did** eventually listen on `podIP:13133`, but under pressure HTTP could hang; DS agents were killed by probes before health was ready.
* Chart default probes used **timeoutSeconds: 1** and **no startupProbe**.

## Before

* resources: cpu 50m/200m, memory **100Mi/200Mi**
* No startupProbe; readiness/liveness default timeouts
* `service.telemetry.metrics.level: detailed`

## After

* resources: cpu 50m/**400m**, memory **128Mi/384Mi** (GOMEMLIMIT auto ~307MiB)
* startupProbe on `/`:`13133` (period 10s, timeout 5s, failureThreshold 36 ≈ 6 min)
* readiness timeout 5s / failureThreshold 6; liveness period 20s / timeout 5s
* telemetry metrics level **basic**
* `presets.hostMetrics.enabled: false` (avoid `/hostfs` scrape under node I/O/memory pressure)
* Operational: `load-generator` scaled to **0** on dev until Critical MNG has headroom (or load-gen is reclassified)

Hard placement (universal DaemonSet + Karpenter taint toleration) is unchanged.

## Technical Design Decisions

* **Raise memory first** — healthy agents already near the old ceiling; packed critical nodes need headroom to finish extension startup.
* **startupProbe** — prevents liveness from killing slow starts under node pressure.
* **Disable hostMetrics** — stuck agent was in kernel `D` state with no listeners; hostfs scrape is a known heavy path on tight nodes.
* **basic self-telemetry** — `detailed` increases agent self-export cost into the same collector.
* **Capacity is mandatory** — chart tuning alone failed until Critical MNG memory dropped (~96% → ~55% after load-generator scale-down).

## Implementation Details

1. Updated `opentelemetry-collector` block in `values.yaml` (resources, probes, hostMetrics off, telemetry level).
2. Live-applied matching DaemonSet/ConfigMap and scaled `load-generator` to 0 for capacity proof.
3. Documented incident evidence and validation steps in this change record.

## Files Changed

**Configuration:**

* `values.yaml` — otel-collector-agent resources, probes, hostMetrics off, telemetry level.

**Documentation:**

* `docs/changes/2026-07-11-fix-otel-agent-health-probe-storm.md` — this change record.

## Dependencies and Cross-Repository Impact

* Critical MNG remains capacity-constrained (`t4g.medium`). If agents still Pending on schedule, enlarge system nodes in `techx-corp-infra` (separate change).
* No Terraform required for this chart-only fix.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Agents should become Ready on all nodes including packed Critical MNG |
| **Infrastructure** | Slightly higher DaemonSet memory request per node |
| **Deployment** | Argo/Helm rolls DaemonSet (brief per-node collector gap) |
| **Observability** | Restores node-local OTLP + kubelet/cluster metrics; hostmetrics off until capacity healthy; self-metrics less verbose |
| **Reliability** | Ends probe restart storm on critical node |
| **Backward compatibility** | Service OTLP endpoints unchanged |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-dev.yaml` | ✅ Pass |

### Manual Verification

* Pre-fix: agent on `ip-10-1-10-52` Unhealthy on `:13133`; process `State: D`; node ~96% memory.
* After resources/probes/hostMetrics=false + scale load-generator → 0: node ~55% memory; agent **`1/1 Ready`**; health `Server available`.
* Other agents remained Ready through the roll.

### Remaining Verification (Post-Merge)

* Commit/sync chart so Argo does not revert live DaemonSet/ConfigMap patches.
* Do **not** restore load-generator on Critical MNG until capacity is enlarged or load-gen is moved off `workload-class=critical`.
* Follow-up infra: larger `system-*` instance type / desired capacity.

## Migration or Deployment Notes

1. Sync chart to `techx-corp-dev`.
2. DaemonSet rolling update restarts agents node-by-node.
3. Optional emergency patch (until Git sync): raise DS resources + startupProbe to match this change.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Insufficient memory to schedule 128Mi request | Low | Medium | Lower request or enlarge system MNG |
| Still thrash if Critical MNG stays >95% memory | Medium | Medium | Enlarge system nodes / move load-generator off critical |

**Rollback procedure:**

1. Revert `values.yaml` otel-collector block.
2. Re-sync chart.
