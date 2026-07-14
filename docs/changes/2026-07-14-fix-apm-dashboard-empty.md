# Change: Fix empty APM Dashboard (variable defaults + env-aware resource context)

## Summary

The Grafana APM Dashboard stayed empty because panel queries filter on
`deployment_environment_name`, `service_namespace`, and `service_name`, while the
dashboard defaults (`demo` / `techx-corp`) did not match labels emitted by the
OpenTelemetry Collector (`production` / `techx-corp-prod`). This change aligns
dashboard variable defaults with production labels, pins the same attributes
explicitly in the prod overlay, and overrides them for development so each
environment’s APM filters resolve correctly after Argo sync and new traffic.

## Context

* APM Dashboard (`grafana/provisioning/dashboards/apm-dashboard.json`) is
  service-scoped: every RED/log/trace panel requires matching Environment,
  Namespace, and Name variables derived from Prometheus `target_info`.
* Collector `resource` processor (added 2026-07-13) already upserts
  `deployment.environment.name=production` and `service.namespace=techx-corp-prod`
  in base `values.yaml`, but:
  * Dashboard defaults still selected non-existent `demo` / `techx-corp`.
  * Dev had no overlay, so dev clusters also emitted production labels.
* Why now: operators open APM and see blank panels despite healthy Prometheus /
  OTel pipelines and storefront traffic.

## Before

* APM Environment default: `demo`; Namespace default: `techx-corp`.
* Collector resource attributes: production / techx-corp-prod only in base
  `values.yaml`; no explicit prod overlay; no dev override.
* Selecting default variables filtered for series that did not exist → empty
  panels. Environment / Namespace could also show `<<not defined>>` for
  pre-fix telemetry missing those attributes.

## After

* APM Environment default: `production`; Namespace default: `techx-corp-prod`.
* Environment variable uses the Prometheus datasource UID
  `${prometheus_datasource}` (consistent with Namespace / Name).
* Service Name variable uses `${prometheus_datasource}` instead of a hard-coded
  datasource UID.
* `values-prod.yaml` explicitly sets production / techx-corp-prod resource
  attributes (same as base; documents intent and resists base drift).
* `values-dev.yaml` overrides to `development` / `techx-corp-dev`.

## Technical Design Decisions

* **Chart-only fix** — APM provisioning and collector config for EKS live in
  `techx-corp-chart`. Platform Compose Grafana copy is out of scope.
* **Overlay arrays replace** — Helm list merge replaces `resource.attributes`
  entirely; each overlay includes the full three-attribute list (including
  `service.instance.id` insert).
* **Prod defaults in dashboard JSON** — Base chart is production-oriented; dev
  Grafana still loads variables from live `target_info` on refresh. Operators on
  dev select `development` / `techx-corp-dev` if the saved current is not present
  (Grafana refresh usually surfaces the real values).
* **No backfill** — Telemetry collected before collector rollout keeps old
  labels; evidence requires traffic after sync.

Alternatives considered:

* Remove Environment/Namespace filters from panels — rejected (loses multi-env
  isolation and matches upstream OpenTelemetry APM design).
* Template collector config with `.Release.Namespace` in the parent chart —
  rejected for this change; would require custom templates around the subchart
  config. Explicit overlays match existing GitOps layering.

## Implementation Details

1. Updated APM dashboard templating defaults and datasource wiring for the three
   filter variables.
2. Documented production resource attributes on the base collector `resource`
   processor comment block.
3. Added explicit `opentelemetry-collector.config.processors.resource` attributes
   in `values-prod.yaml` and `values-dev.yaml`.
4. Recorded this change document and per-file change trails.

## Files Changed

**Grafana:**
* `grafana/provisioning/dashboards/apm-dashboard.json` — Environment/Namespace
  defaults to `production` / `techx-corp-prod`; Prometheus datasource UIDs
  unified on `${prometheus_datasource}`.

**Configuration:**
* `values.yaml` — Comment documenting APM resource attributes (prod defaults
  unchanged: `production` / `techx-corp-prod`).
* `values-prod.yaml` — Explicit production collector resource attributes.
* `values-dev.yaml` — Development collector resource attributes
  (`development` / `techx-corp-dev`).

**Documentation:**
* `docs/changes/2026-07-14-fix-apm-dashboard-empty.md` — This change record.

Change trail exception for `grafana/provisioning/dashboards/apm-dashboard.json`:
JSON does not support comments. Trail recorded here and attributed to `@hungxqt`.

## Dependencies and Cross-Repository Impact

None. Platform local Grafana under `techx-corp-platform/src/grafana/` is
unchanged. No infra Terraform changes.

Related historical: `docs/changes/2026-07-13-apm-resource-context.md` (initial
collector attribute upsert).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No service code change |
| **Infrastructure** | No Terraform change |
| **Deployment** | Argo CD Helm sync rolls collector DaemonSet + Grafana dashboard ConfigMap |
| **Performance** | None (fixed two labels already present in prod base) |
| **Security** | No change |
| **Reliability** | APM becomes usable for triage after sync + traffic |
| **Cost** | Negligible (fixed-cardinality labels) |
| **Backward compatibility** | Dashboard defaults no longer use `demo` / `techx-corp`; saved Grafana user preferences may still override until reset |
| **Observability** | Dev telemetry labeled `development` / `techx-corp-dev` instead of prod strings |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (prod layering) | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Pass (icon info only) |
| Helm lint (dev layering) | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-dev.yaml` | Pass (icon info only) |
| Template contains prod attrs | `helm template ... -f values-prod.yaml` | `production` / `techx-corp-prod` on resource processor |
| Template contains dev attrs | `helm template ... -f values-dev.yaml` | `development` / `techx-corp-dev` on resource processor |
| Dashboard defaults | Inspect JSON Environment/Namespace `current` | `production` / `techx-corp-prod` |

### Manual Verification

* Confirm rendered collector ConfigMap/DaemonSet config for prod includes
  `deployment.environment.name: production` and
  `service.namespace: techx-corp-prod`.
* Confirm dev render includes `development` / `techx-corp-dev`.
* Confirm APM JSON `current` values are `production` and `techx-corp-prod`.

### Remaining Verification (Post-Merge)

1. Argo CD sync for the target cluster(s); wait for `otel-collector` DaemonSet
   rollout and Grafana ConfigMap reload / pod restart if needed.
2. Generate storefront or load-generator traffic.
3. Open APM Dashboard; select:
   * Prod: Environment `production`, Namespace `techx-corp-prod`, Name e.g.
     `checkout`
   * Dev: Environment `development`, Namespace `techx-corp-dev`, Name e.g.
     `checkout`
4. Confirm RED metrics, traces, and logs populate for the selected service.
5. Optional Prometheus checks:

```cmd
REM After port-forward or in-cluster Explore
REM count by (deployment_environment_name, service_namespace, service_name) (target_info)
```

## Migration or Deployment Notes

1. Merge this chart change; let Argo CD sync (or break-glass Helm upgrade with
   the same values layering as GitOps).
2. No secret or image tag changes required.
3. Old series without the resource attributes remain unusable for APM filters;
   use data after collector rollout only.
4. If Grafana still shows old dashboard defaults, hard-refresh the browser or
   re-open the dashboard so provisioned JSON reloads.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Dev still shows empty until operator picks `development` / `techx-corp-dev` | Medium | Low | Variable refresh lists live values; document post-sync steps |
| Helm array replace drops other resource attributes if someone edits overlay incompletely | Low | Medium | Keep full three-attribute lists in each overlay; lint/template check |
| Collector fails to start (config syntax) | Low | High | Argo health; rollback Git revision |

**Rollback procedure:**

1. Revert this commit in `techx-corp-chart`.
2. Argo CD sync previous revision (or Helm rollback to prior release revision).
3. Confirm collector DaemonSet healthy and APM dashboard ConfigMap restored.

<!-- Change trail: @hungxqt - 2026-07-14 - Fix empty APM dashboard defaults and env-aware OTEL resource attributes. -->
