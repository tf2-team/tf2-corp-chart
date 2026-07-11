# REL-08 Rollout Safety Plan & Runbook

This document details the rollout safety mechanisms, release commands, validation checklist, and rollback procedures for `techx-corp-chart`.

## Rollout Architecture & Safety Controls

1. **Readiness Probes**: Kubernetes readiness probes are configured on all critical services by type (gRPC, HTTP, or TCP). Probes ensure that traffic is not routed to newly spawned pods until they are fully functional. Handler choice, liveness pairing, and per-service thresholds are documented in [probe-thresholds.md](./probe-thresholds.md).
2. **RollingUpdate Policy**:
   - Default services are configured with a zero-downtime rolling update strategy (`maxUnavailable: 0`, `maxSurge: 1`).
   - Singleton data/broker components (`postgresql`, `kafka`, `valkey-cart`) are configured with a non-surge strategy (`maxUnavailable: 1`, `maxSurge: 0`) to prevent volume mount conflicts (e.g., ReadWriteOnce persistence limits).
   > [!IMPORTANT]
   > Singleton data/broker components (`postgresql`, `kafka`, `valkey-cart`) are not zero-downtime. Zero-downtime upgrades for these components require high-availability (HA) storage and clustered replication configurations which are outside the scope of this rollout safety plan.
3. **Helm Deploy Gates**: The deployment command uses `--wait` and `--atomic` options, forcing Helm to wait for all resources to become ready, and automatically rolling back the release if the deployment fails or times out.
4. **Post-Deployment Smoke Gate**: Running `smoke-test.sh` immediately after deployment ensures the application functions correctly at the API level (homepage, product catalog, cart addition, and checkout flow).

---

## Deployment Procedure

### 1. Pre-Deployment Check
Before upgrading, operators must record the current state of the release for auditability and manual rollback references:

```bash
# Record release revision history
helm history techx-corp -n techx-corp

# Record the exact active values of the current release
helm get values techx-corp -n techx-corp --all > pre-deploy-values.yaml
```

### 2. Execution Command
Perform the upgrade/install using the standardized safe deployment command:

```bash
helm upgrade --install techx-corp techx-corp-chart \
  -n techx-corp --create-namespace \
  --wait --atomic --timeout 10m --history-max 10
```

*Parameters explained:*
* `--wait`: Wait until all Pods, PVCs, Services, and ingress resources are in a ready state before marking the release as successful.
* `--atomic`: If any resource fails to become ready or the operation times out, Helm will automatically roll back the release to the previous successful revision.
* `--timeout 10m`: Allows up to 10 minutes for slow pull times or complex state initializations before failing.
* `--history-max 10`: Limits history retention to prevent configmap bloating in the cluster.

### 3. Post-Deployment Verification
Immediately run the smoke test script to validate application health:

```bash
bash techx-corp-chart/scripts/smoke-test.sh --namespace techx-corp
```

---

## Rollback Procedure

### Rollback Triggers
Operators must trigger a manual rollback if any of the following occur:
- Helm command times out or fails (should trigger auto-rollback due to `--atomic`, but must be verified).
- Any critical Deployment is not `Ready` (e.g. `frontend`, `frontend-proxy`, `checkout`, `payment`, `product-catalog`) after the rollout.
- Post-deployment smoke test fails.
- Visible HTTP 5xx errors or significant latency spikes are detected on the storefront or checkout path.

### Rollback Execution

1. Identify the previous good revision number from the pre-deployment history output (e.g. `Revision: 5`).
2. Execute the rollback command:

```bash
helm rollback techx-corp <PREVIOUS_GOOD_REVISION> -n techx-corp --wait --timeout 10m
```

### Post-Rollback Validation
After executing a rollback, verify that the critical deployments are restored and stable:

```bash
# Verify rollout status of critical components
kubectl -n techx-corp rollout status deploy/frontend-proxy --timeout=300s
kubectl -n techx-corp rollout status deploy/frontend --timeout=300s
kubectl -n techx-corp rollout status deploy/checkout --timeout=300s
kubectl -n techx-corp rollout status deploy/payment --timeout=300s

# Re-run smoke tests to confirm storefront restoration
bash techx-corp-chart/scripts/smoke-test.sh --namespace techx-corp
```
