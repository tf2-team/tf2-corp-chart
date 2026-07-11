# Change: OTEL service.namespace from Helm release namespace

## Context

`resource.opentelemetry.io/service.namespace` was hard-coded to `techx-corp` on every component `podAnnotations` in `values.yaml`. That is wrong for multi-environment installs (for example Helm `-n techx-corp-dev`), because telemetry kept reporting logical namespace `techx-corp` even when workloads ran in `techx-corp-dev`.

## Before

- Each component repeated:
  - `resource.opentelemetry.io/service.namespace: techx-corp`
- Dev and prod both emitted the same OTEL service namespace regardless of `-n` / release namespace.

## After

- Deployment/StatefulSet pod template injects:
  - `resource.opentelemetry.io/service.namespace: <Release.Namespace>`
- Component values no longer hard-code that key. Existing scrape-related annotations (frontend-proxy, image-provider, postgresql, valkey-cart) are unchanged.
- Per-component override remains possible by setting the same annotation key under `podAnnotations` (mergeOverwrite: values win over the default).

## Implementation

1. In `templates/_objects.tpl`, merge a default annotation dict from `.Release.Namespace` with component `podAnnotations`.
2. Remove all hard-coded `resource.opentelemetry.io/service.namespace: techx-corp` lines from `values.yaml`, and drop empty `podAnnotations:` keys that only held that value.

## Files Changed

* `templates/_objects.tpl`
  * Inject OTEL `service.namespace` from `.Release.Namespace` into pod annotations.
* `values.yaml`
  * Remove hard-coded OTEL service.namespace annotations; keep residual metrics scrape annotations only.
* `docs/changes/2026-07-10-otel-service-namespace-from-release.md`
  * This change record.

## Impact

* **Application behavior:** Unchanged runtime paths.
* **Observability:** `service.namespace` on component pods matches the Helm install namespace (`techx-corp-dev` vs `techx-corp` / prod target).
* **Backward compatibility:** Dashboards/filters that assumed a fixed `techx-corp` service.namespace for dev data need to use the real release namespace (or `k8s.namespace.name`).

## Validation

```bash
helm template techx-corp-dev . \
  -f values.yaml -f values-public-alb.yaml -f values-dev.yaml \
  --namespace techx-corp-dev

helm template techx-corp-prod . \
  -f values.yaml -f values-public-alb.yaml -f values-prod.yaml \
  --namespace techx-corp
```

Confirmed rendered annotations:

* Dev: 22× `resource.opentelemetry.io/service.namespace: techx-corp-dev`
* Prod: 22× `resource.opentelemetry.io/service.namespace: techx-corp`

## Migration or Deployment Notes

None beyond a normal chart upgrade/sync. No secret or namespace migration.

## Risks and Rollback

* Risk: existing Grafana variables or alerts filtered only on `service.namespace=techx-corp` may miss dev series until updated.
* Rollback: restore previous `_objects.tpl` annotation block and hard-coded values keys, or set an explicit override under each component `podAnnotations`.
