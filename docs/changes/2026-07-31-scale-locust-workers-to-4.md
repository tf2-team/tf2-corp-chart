# Change: Scale Locust Master and Workers to 4 Replicas

## Summary

Increased the `load-generator` (Locust Master) deployment to 1 replica (with `LOCUST_EXPECT_WORKERS: "4"`) and `load-generator-worker` (Locust Workers) deployment to 4 replicas in the Helm chart configurations.

## Context

To run synthetic load simulations against the storefront microservices, the Locust load testing cluster requires 1 active master pod and 4 worker pods to generate distributed virtual user traffic.

## Before

`load-generator` master and `load-generator-worker` were configured with 0 default replicas (`replicas: 0`) in resting configuration, causing 0 running pods in `techx-corp-prod`.

## After

`load-generator` master is set to 1 replica with `LOCUST_EXPECT_WORKERS: "4"`, and `load-generator-worker` is set to 4 replicas across base `values.yaml`, production overlay `values-prod.yaml`, and `values-loadgen-worker-4.yaml`.

## Technical Design Decisions

- **Master / Worker Coordination**: Set `LOCUST_EXPECT_WORKERS` to `4` on the master container so the autostart swarm waits for all 4 worker nodes to register before launching synthetic traffic.
- **Karpenter Spot Placement**: Workers are scheduled on Karpenter Spot nodes (`workload-class: spot-tolerant`) to maintain anti-affinity with customer-facing microservices.

## Implementation Details

1. Updated `values.yaml` to set `components.load-generator.replicas: 1`, `LOCUST_EXPECT_WORKERS: "4"`, and `components.load-generator-worker.replicas: 4`.
2. Updated `values-prod.yaml` to set `components.load-generator.replicas: 1`, `LOCUST_EXPECT_WORKERS: "4"`, and `components.load-generator-worker.replicas: 4`.
3. Updated `values-loadgen-worker-4.yaml` overlay.
4. Validated rendered manifests via `helm lint` and `helm template`.

## Files Changed

**Configuration:**
* `values.yaml` — Updated `load-generator` master replicas to 1, `LOCUST_EXPECT_WORKERS` to 4, and `load-generator-worker` replicas to 4.
* `values-prod.yaml` — Updated `load-generator` master replicas to 1, `LOCUST_EXPECT_WORKERS` to 4, and `load-generator-worker` replicas to 4.
* `values-loadgen-worker-4.yaml` — Updated overlay with master 1 and worker 4 replicas.

**Documentation:**
* `docs/changes/2026-07-31-scale-locust-workers-to-4.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Self-contained within `techx-corp-chart`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Locust master spins up 1 pod; Locust workers spin up 4 pods generating synthetic traffic to `frontend-proxy:8080`. |
| **Infrastructure** | Karpenter provisions Spot capacity for 4 worker pods. |
| **Deployment** | Argo CD syncs updated replicas in `techx-corp-prod`. |
| **Performance** | Distributed load generation scaled to 4 worker instances. |
| **Security** | No change to network policies or security contexts. |
| **Reliability** | Master pod runs on critical MNG nodes; workers run on Spot nodes. |
| **Cost** | Spot instance usage for 4 worker pods during test run. |
| **Backward compatibility** | Fully backward compatible. |
| **Observability** | Prometheus scrapes Locust master metrics on port 8089. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm template | `helm template techx-corp . -f values-prod.yaml` | ✅ Pass |
| Schema validation | `helm lint . -f values-prod.yaml` | ✅ Pass |

### Manual Verification

Verified rendered deployment manifests:
- `Deployment/load-generator` has `replicas: 1` and `LOCUST_EXPECT_WORKERS: "4"`.
- `Deployment/load-generator-worker` has `replicas: 4`.

## Migration or Deployment Notes

Argo CD will automatically sync the updated Deployment manifests to the cluster upon Git push.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Increased Spot instance cost | Low | Low | Scale replicas back to 0 when testing completes. |

**Rollback procedure:**

Set `replicas: 0` in `values-prod.yaml` or run `kubectl scale deployment load-generator-worker --replicas=0 -n techx-corp-prod`.

<!-- Change trail: @hungxqt - 2026-07-31 - Document scaling Locust master to 1 and workers to 4. -->
