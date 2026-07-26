# Change: Document OpenSearch Security Image Contract (SEC-06 Option B)

## Summary

Document that the first-party OpenSearch image must retain the vendor `opensearch-security` plugin so chart SEC-06 HTTPS + basic auth clients keep working. Chart runtime endpoints were already correct; the empty Grafana logs / broken traces→logs drilldown was caused by an image that stripped the plugin and left the node on plain HTTP.

## Context

* Production (`techx-corp-prod`, 2026-07-22): OTel Collectors dropped logs with `tls: first record does not look like a TLS handshake` against `https://opensearch:9200` while OpenSearch only spoke HTTP.
* Grafana OpenSearch datasource (`webstore-logs`) could not query over HTTPS; Jaeger traces→logs (`tracesToLogsV2`) therefore returned no data for current traces.
* Stale log indices existed only through `otel-logs-2026-07-14`.
* Fix path Option B: restore security in the platform image; keep chart HTTPS/auth config and clarify the cross-repo contract.

## Before

* Chart values already set `DISABLE_INSTALL_DEMO_CONFIG=false`, OpenSearch exporter `https://opensearch:9200` + basicauth, Grafana datasource HTTPS + basicAuth + `tlsSkipVerify`.
* `values.yaml` comment only said the custom image “strips unused plugins” without requiring security.
* ADR SEC-06 described chart/secret steps but not the mandatory image plugin contract.

## After

* `values.yaml` comment states the custom image must **keep** `opensearch-security`.
* ADR SEC-06 adds a “Platform image contract” section describing the HTTPS failure mode when the plugin is missing.
* No endpoint or secret shape change (clients already match SEC-06).

## Technical Design Decisions

* **No chart protocol flip to HTTP:** That would be Option A and weaken SEC-06. Chart stays on HTTPS.
* **Docs-only in chart:** Runtime YAML for exporter/datasource was already correct; changing it would not fix a security-less image.
* **Cross-repo linkage:** Platform change doc owns the Dockerfile; this chart doc owns contract documentation and operator verification for GitOps.

## Implementation Details

1. Update OpenSearch component comment in `values.yaml`.
2. Extend ADR SEC-06 with image contract + failure symptom.
3. Record this change for operators promoting the fixed image tag.

## Files Changed

**Configuration:**
* `values.yaml` — OpenSearch image comment (retain security plugin).

**Documentation:**
* `docs/adr/SEC-06-opensearch-auth.md` — Platform image contract section.
* `docs/changes/2026-07-22-opensearch-security-image-contract.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Depends on:** `techx-corp-platform` image rebuild that keeps `opensearch-security` (see `techx-corp-platform/docs/changes/2026-07-22-opensearch-retain-security-plugin.md`).
* After the new platform image tag is published, promote `default.image.tag` (and service digest overlays if used) so `opensearch` StatefulSet rolls to the fixed image.
* Chart HTTPS/basic auth settings require no further code change for the log pipeline to resume once the image is correct.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None from chart-only text changes |
| **Deployment** | Operator must deploy platform image then chart tag promote; Argo CD sync |
| **Observability** | After image promote: log export and Grafana logs / traces→logs drilldown recover |
| **Security** | Restores intended SEC-06 posture when paired with fixed image |
| **Backward compatibility** | Unchanged chart API; image without security remains incompatible with this chart |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (local) | `helm lint . -f values.yaml -f values-prod.yaml` | Pending operator (no template logic change) |
| Doc consistency | Manual: ADR + values comment match platform Dockerfile | ✅ |

### Manual Verification

Pre-fix (completed during diagnosis):

* OpenSearch HTTP OK, HTTPS fail
* Collector TLS drop errors
* No recent `otel-logs-*`

Post image promote (operator):

```cmd
kubectl -n techx-corp-prod get pod opensearch-0
kubectl -n techx-corp-prod exec opensearch-0 -- ls /usr/share/opensearch/plugins
REM expect: opensearch-security present
kubectl -n techx-corp-prod logs -l app.kubernetes.io/name=opentelemetry-collector --since=5m
REM expect: no sustained opensearch TLS handshake drop errors
```

Grafana:

* Explore → OpenSearch → recent time range has logs
* Explore → Jaeger → open a span → “Logs for this span” returns data when apps log with `traceId`/`spanId`

### Remaining Verification (Post-Merge)

1. Wait for platform CI image containing security plugin.
2. Promote tag via normal GitOps path (dev auto-tag if applicable; prod chart PR).
3. Confirm new daily `otel-logs-*` index and drilldown UX.

## Migration or Deployment Notes

1. Deploy **platform image first** (or same release window, but OpenSearch must run the new image before expecting logs).
2. Chart text-only change can merge anytime; functional recovery waits on image.
3. Confirm `techx-corp-opensearch` secret is Ready and password meets OpenSearch strength rules.
4. After Argo sync, wait for OpenSearch Ready, then collector/Grafana if they rolled.
5. Do **not** set collector/Grafana back to `http://` while this contract is active.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Docs merge without image promote leaves prod broken | High until image ships | High | Promote fixed `opensearch` image as part of the same change window |
| Demo TLS bootstrap failure on roll | Low | High | Follow ADR verify curl; check `DISABLE_INSTALL_DEMO_CONFIG=false` |
| Operators re-strip security in a future image | Medium | High | ADR + values comment + platform Dockerfile asserts |

**Rollback procedure:**

* Chart docs: revert this commit (no runtime effect alone).
* Functional rollback of security posture requires coordinated image + client endpoint changes; prefer fixing the security-enabled image forward.

<!-- Change trail: @hungxqt - 2026-07-22 - Document SEC-06 OpenSearch image security contract. -->
