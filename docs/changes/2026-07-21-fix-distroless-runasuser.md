# Change: Numeric runAsUser for Checkout, Product-Catalog, Shipping

## Summary

Set explicit `securityContext.runAsUser` / `runAsGroup` `65532` (with `runAsNonRoot: true`) for checkout, product-catalog, and shipping so kubelet can verify non-root when the image declares a named user such as `nonroot`.

## Context

These three workloads failed with:

```text
Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

Default component `securityContext` already sets `runAsNonRoot: true` but does **not** set a numeric `runAsUser`. When the image `USER` is a name rather than a number, kubelet refuses to start the container. Distroless `:nonroot` uses UID **65532**.

## Before

* checkout, product-catalog, and shipping inherited the default security context without `runAsUser`.
* Pods failed at create when the image USER was the string `nonroot`.

## After

Each of the three components has:

```yaml
securityContext:
  runAsUser: 65532
  runAsGroup: 65532
  runAsNonRoot: true
```

Merged with the default component security context (capabilities drop, read-only root, no privilege escalation).

## Technical Design Decisions

* **Component-level override vs changing the global default.** Other services need different UIDs (envoy 101, nginx 101, frontend/next patterns, etc.). Only these three distroless nonroot services needed 65532.
* **Match distroless nonroot UID 65532** rather than 10001, which is used by other first-party images that create their own user.
* **Pair with platform Dockerfile change** that sets `USER 65532` so image metadata and pod spec agree after rebuild.

## Implementation Details

1. Added `securityContext` under `components.checkout`.
2. Added `securityContext` under `components.product-catalog`.
3. Added `securityContext` under `components.shipping`.

## Files Changed

**Configuration:**
* `values.yaml` — numeric `runAsUser`/`runAsGroup` 65532 for checkout, product-catalog, shipping.

**Documentation:**
* `docs/changes/2026-07-21-fix-distroless-runasuser.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-21-fix-distroless-numeric-user.md` (Dockerfile `USER 65532`).
* Chart-only deploy can unblock pods against existing images that still say `USER nonroot`, because an explicit numeric `runAsUser` satisfies kubelet without relying on image USER.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Process runs as UID/GID 65532 |
| **Infrastructure** | No change |
| **Deployment** | GitOps sync of chart values; no direct Helm/kubectl mutation |
| **Performance** | None |
| **Security** | Explicit non-root UID in pod spec |
| **Reliability** | Fixes CreateContainerConfigError for the three services |
| **Cost** | None |
| **Backward compatibility** | Compatible with distroless nonroot images |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values review | Grep `runAsUser: 65532` under checkout / product-catalog / shipping | ✅ Present |

### Manual Verification

* Confirmed template merge uses component `securityContext` over defaults (`templates/_objects.tpl`).

### Remaining Verification (Post-Merge)

* After Argo CD sync, confirm the three Deployments show Ready pods and no CreateContainerConfigError events.

## Migration or Deployment Notes

1. Commit and push chart change; let Argo CD auto-sync.
2. Optionally rebuild platform images with numeric `USER 65532` for image-layer consistency.
3. Do **not** run direct `helm upgrade` / `kubectl patch` against Argo-managed resources.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| File ownership mismatch if a future image runs as a different UID | Low | Medium | Keep Dockerfile USER and chart runAsUser aligned at 65532 |

**Rollback procedure:**

Revert the three `securityContext` blocks in `values.yaml` and sync via GitOps. Only do so after images use a numeric non-root USER or another numeric `runAsUser` is in place.

<!-- Change trail: @hungxqt - 2026-07-21 - Document runAsUser 65532 for checkout, product-catalog, shipping -->
