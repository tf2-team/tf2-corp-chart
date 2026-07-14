# Change: Fix OpenSearch CrashLoop — enable demo SSL for SEC-06 security plugin

## Summary

OpenSearch pods crash-looped after SEC-06 with `OpenSearchException[No SSL configuration found]`. The security plugin was enabled while `DISABLE_INSTALL_DEMO_CONFIG=true` left no TLS material. This change installs demo self-signed certs at bootstrap and points OTel Collector / Grafana at `https://opensearch:9200` with TLS verify skipped on the cluster network.

## Context

SEC-06 removed `DISABLE_SECURITY_PLUGIN: "true"` and injected `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, but left `DISABLE_INSTALL_DEMO_CONFIG: "true"` (the pre-SEC-06 setting used when security was fully disabled).

With the security plugin loaded and no PEM/demo certs:

```
failed to load plugin class [org.opensearch.security.OpenSearchSecurityPlugin]
Caused by: OpenSearchException[No SSL configuration found]
→ container exit 1 → CrashLoopBackOff
```

Observed on prod: `opensearch-0` in `techx-corp-prod`, image `…/techx-prod-corp/opensearch:sha-20dd45f`. OTel collectors were dropping logs with `connection refused` to `:9200`.

## Before

* `components.opensearch.env`: `DISABLE_INSTALL_DEMO_CONFIG=true`, security plugin on, no custom certs
* Collector exporter: `http://opensearch:9200`
* Grafana datasource: `http://opensearch:9200/`
* Ops docs suggested alphanumeric-only OpenSearch passwords (conflicts with OpenSearch strength rules requiring a special character)

## After

* `DISABLE_INSTALL_DEMO_CONFIG=false` so demo TLS certs are generated for single-node bootstrap
* Collector exporter: `https://opensearch:9200` with existing `tls.insecure: true`
* Grafana datasource: `https://opensearch:9200/` with `jsonData.tlsSkipVerify: true`
* Docs/ADR updated: HTTPS clients, password must include a special character

## Technical Design Decisions

* **Demo TLS certs vs custom PEMs:** Custom cert management (CSRs, rotation, volume mounts) is out of scope for the single-node log store. Demo self-signed certs match the OpenSearch Docker single-node pattern; traffic stays in-cluster and clients skip verify.
* **HTTPS (not HTTP with security):** Security plugin requires SSL config at load time; disabling HTTP SSL still needs transport PEMs. Demo install is the smallest fix that satisfies the plugin.
* **Skip TLS verify in-cluster:** Acceptable trade-off until proper internal CA/cert-manager is introduced; NetworkPolicy + basic auth remain the primary controls.
* **Password special character:** OpenSearch enforces upper/lower/digit/special. Previous “alphanumeric-only for DSN safety” guidance does not apply here (basic auth, not DSN concatenation).

## Implementation Details

1. Set `DISABLE_INSTALL_DEMO_CONFIG` to `"false"` with comments explaining the SSL requirement.
2. Switch otel-collector `opensearch` exporter endpoint to HTTPS.
3. Switch Grafana OpenSearch datasource URL to HTTPS and add `tlsSkipVerify`.
4. Update SEC-06 ADR verify curl to `https://` and document demo SSL + password rules.
5. Correct `docs/operations/external-secrets.md` OpenSearch password guidance.

## Files Changed

**Configuration:**
* `values.yaml` — OpenSearch env (`DISABLE_INSTALL_DEMO_CONFIG=false`); collector HTTPS endpoint
* `grafana/provisioning/datasources/opensearch.yaml` — HTTPS URL + `tlsSkipVerify`

**Documentation:**
* `docs/adr/SEC-06-opensearch-auth.md` — demo SSL requirement, HTTPS verify, password rules
* `docs/operations/external-secrets.md` — OpenSearch password special-character requirement
* `docs/changes/2026-07-14-fix-opensearch-ssl-demo-config.md` — this change record

## Dependencies and Cross-Repository Impact

* No platform image rebuild required (runtime env + client URL only).
* ASM secret `techx-corp/<env>/opensearch` password **must** include a special character or first-start bootstrap fails after SSL is fixed.
* Related: `docs/changes/2026-07-13-sec-06-opensearch-security-plugin.md` (incomplete without this fix).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Storefront unchanged; log pipeline recovers once OpenSearch Ready |
| **Observability** | OpenSearch healthy; collectors can export logs again over HTTPS + basic auth |
| **Deployment** | Requires chart sync (Argo/Helm); may need ASM password update + optional PVC reset if security index conflicts |
| **Security** | Security plugin remains on; TLS is demo self-signed (in-cluster skip-verify) |
| **Backward compatibility** | Clients must use HTTPS; plain HTTP to :9200 will fail after fix |
| **Reliability** | Removes CrashLoopBackOff root cause for SEC-06 bootstrap |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint | `helm lint . -f values.yaml -f values-prod.yaml` | Pending operator / CI |
| Template | Confirm `DISABLE_INSTALL_DEMO_CONFIG` is `false` and endpoints are `https://` | Pending |

### Manual Verification

* Prod before fix: logs show `No SSL configuration found`; pod CrashLoopBackOff.
* After deploy:
  * `kubectl -n techx-corp-prod get pod opensearch-0` → `1/1 Running`
  * `curl -sk -u admin:<password> https://localhost:9200/_cluster/health` → green/yellow
  * Collector logs: no sustained `connection refused` / auth failures on opensearch exporter

### Remaining Verification (Post-Merge)

1. Argo CD sync `techx-corp` (or break-glass helm upgrade).
2. Confirm ASM password meets OpenSearch strength rules; force ESO refresh if rotated.
3. Smoke Grafana Explore → OpenSearch datasource.

## Migration or Deployment Notes

1. **Password (if current value lacks a special character):**

```cmd
aws secretsmanager put-secret-value --region us-east-1 ^
  --secret-id techx-corp/production/opensearch ^
  --secret-string "{\"username\":\"admin\",\"password\":\"<StrongPassw0rd!ReplaceMe>\"}"
```

```cmd
kubectl annotate externalsecret techx-corp-opensearch -n techx-corp-prod force-sync=%DATE%-%TIME% --overwrite
kubectl rollout restart statefulset/opensearch -n techx-corp-prod
```

2. Deploy this chart revision (Git push → Argo auto-sync, or helm upgrade).
3. If the node still fails after SSL fix because an old PVC has conflicting security metadata, delete the PVC (log history only) and let the StatefulSet recreate it:

```cmd
kubectl delete pod opensearch-0 -n techx-corp-prod
kubectl delete pvc opensearch-data-opensearch-0 -n techx-corp-prod
```

4. Restart collectors if they cached connection errors (usually self-recover):

```cmd
kubectl rollout restart daemonset -n techx-corp-prod -l app.kubernetes.io/name=opentelemetry-collector
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Weak ASM password (no special char) blocks bootstrap after SSL fix | Medium | High | Update ASM before/with deploy; document strength rules |
| PVC security-index conflict after prior non-security data | Low–Medium | Medium | Delete PVC; accept log history loss |
| Argo reverts live kubectl patches until Git is synced | High if only live-patched | Medium | Land chart change on `main` promptly |
| Demo certs not suitable for external exposure | Low (not exposed) | Low | Keep OpenSearch internal-only; future cert-manager |

**Rollback procedure:**

1. Re-set `DISABLE_SECURITY_PLUGIN: "true"` and `DISABLE_INSTALL_DEMO_CONFIG: "true"` if full security rollback is required (see SEC-06 ADR).
2. Or re-set only `DISABLE_INSTALL_DEMO_CONFIG: "true"` **without** security on (invalid combo if security stays enabled).
3. `helm upgrade` / Git revert of this change; restart OpenSearch. PVC wipe may still be needed if security index was written.
