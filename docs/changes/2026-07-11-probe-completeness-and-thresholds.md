# Change: Probe completeness and per-service thresholds

## Summary

First-party workloads in `values.yaml` now have complete readiness coverage for documented serving and dependency components, matching liveness probes (with cart using tcp liveness for chaos safety), corrected frontend-proxy Envoy admin readiness, and explicit per-tier timings. Operator rationale is documented in `docs/operations/probe-thresholds.md`.

## Context

* REL-02 / REL-08 and `UPGRADING.md` described probes that were incomplete or drifted (missing `recommendation`, `image-provider`, `llm`; frontend-proxy used data-plane `/` instead of admin `/ready`).
* Almost only OpenSearch had liveness; hung processes on other services would not be restarted by kubelet.
* Kubernetes defaults (`timeoutSeconds: 1`) were too tight under low CPU / Guaranteed profiles.
* Operators needed a single matrix explaining handler choice and failure budgets per service.

## Before

* Readiness-only (no timings) on most apps and datastores.
* No probes on `recommendation`, `image-provider`, `llm`.
* `frontend-proxy` readiness: `httpGet` path `/` port `8080`.
* Only OpenSearch had startup + readiness + liveness with tuned thresholds.
* Workers intentionally unprobed (unchanged policy).

## After

* Full readiness + liveness matrix for serving apps and datastores (see probe-thresholds.md).
* Gaps closed: recommendation (grpc), image-provider (`/status`), llm (tcp :8000).
* `frontend-proxy` uses Envoy admin `GET /ready` on port `10000`.
* cart: readiness grpc (supports `failedReadinessProbe`); liveness **tcpSocket**.
* Tiered timings (A/B/C); OpenSearch Tier D unchanged.
* New operations doc documents every threshold choice.

## Technical Design Decisions

* **Tier model (A/B/C/D)** maps runtime cold-start and resource profile to failure budgets instead of one global timing.
* **cart liveness is tcp, not grpc**, so demo chaos flag fails readiness only.
* **frontend-proxy probes admin `/ready`**, not upstream-coupled data-plane `/`.
* **TCP for services without health routes** (email, quote, shipping, llm, kafka, postgres, valkey, flagd) rather than inventing HTTP paths.
* **No worker network probes** — still requires app-level consumer health (REL-02-FU-01/02).
* **OpenSearch left unchanged** — already validated multi-minute startup budget.

## Implementation Details

1. Authored `docs/operations/probe-thresholds.md` (math, tiers, per-component rationale, compose mapping, tuning runbook).
2. Updated each `components.*` probe block in `values.yaml` to match the matrix (handlers + period/timeout/failureThreshold).
3. Linked probe policy from `docs/operations/rollout-safety.md`.
4. Left templates/schema unchanged (already support all probe types).

## Files Changed

**Configuration:**

* `values.yaml` — Completeness + liveness + per-service thresholds for first-party components.

**Documentation:**

* `docs/operations/probe-thresholds.md` — Threshold design source of truth.
* `docs/operations/rollout-safety.md` — Link to probe-thresholds policy.
* `docs/changes/2026-07-11-probe-completeness-and-thresholds.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart-only. Apps already expose gRPC health, nginx `/status`, and Envoy admin `/ready`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No app code change; kubelet gates traffic and restarts hung containers more predictably |
| **Infrastructure** | No change |
| **Deployment** | Helm upgrade applies new probe fields; rollout may wait slightly longer for Tier C readiness |
| **Performance** | Slightly more probe overhead (liveness); timeouts reduced false failures vs default 1s |
| **Security** | No change |
| **Reliability** | Higher: missing probes filled; liveness recovers hung processes; chaos-safe cart |
| **Cost** | Negligible |
| **Backward compatibility** | Fully compatible chart upgrade; pods may restart once under new liveness if already hung |
| **Observability** | Probe failure Events more meaningful with documented windows |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Lint | `helm lint .` | ✅ Pass (icon warning only) |
| Template | `helm template techx . -f values.yaml` | ✅ Pass — matrix handlers/timings asserted for 20 components; workers unprobed; OpenSearch startup fail 36 |

### Manual Verification

* Rendered manifests: recommendation/image-provider/llm present; frontend-proxy `/ready` :10000; cart readiness grpc / liveness tcp; workers without probes; OpenSearch startup failureThreshold 36 unchanged.

### Remaining Verification (Post-Merge)

* Dev cluster: confirm Ready without CrashLoop for ad, kafka, frontend-proxy, recommendation after sync.
* Operator: watch Events for unexpected Unhealthy during cold start; tune per probe-thresholds.md runbook if needed.

## Migration or Deployment Notes

1. Deploy/sync chart as usual (Argo CD or `helm upgrade --wait --atomic`).
2. No secret or infra prerequisite changes.
3. If frontend-proxy fails Ready, verify Envoy admin listens on 10000 before rolling back probe path.
4. Optional: enable cart `failedReadinessProbe` flag and confirm pod stays Running (NotReady only).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Tier C still tight under extreme throttle | Low | Medium | Raise failureThreshold per probe-thresholds.md |
| Envoy `/ready` misconfiguration | Low | High | Revert frontend-proxy probe to previous values |
| Liveness restarts under load | Low | Medium | Increase liveness timeout/failureThreshold |

**Rollback procedure:**

Revert `values.yaml` probe blocks (and docs if desired) to the previous chart revision and redeploy/sync that revision.
