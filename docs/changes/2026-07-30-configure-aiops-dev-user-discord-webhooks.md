# Change: Configure Dev and User Discord Webhooks for AIOps Runtime

## Summary

Replaced the legacy single `AIOPS_NOTIFICATION_WEBHOOK_URL` environment variable in the `aiops-runtime` deployment template with dedicated `AIOPS_NOTIFICATION_DEV_WEBHOOK_URL` and `AIOPS_NOTIFICATION_USER_WEBHOOK_URL` environment variables.

## Context

The AIOps runtime supports routing notifications to distinct developer (`dev`) and user/operational (`user`) Discord channels for technical root cause detail versus user-facing impact summaries. Previously, the Helm chart only rendered a single fallback `AIOPS_NOTIFICATION_WEBHOOK_URL` referencing `techx-corp-grafana-discord`.

## Before

`templates/aiops.yaml` rendered only `AIOPS_NOTIFICATION_WEBHOOK_URL` when `aiops.notificationSecretRef` was provided. `values.yaml` and overlays (`values-aiops.yaml`, `values-aiops-live-approved.yaml`) referenced the single `notificationSecretRef`.

## After

`templates/aiops.yaml` renders `AIOPS_NOTIFICATION_DEV_WEBHOOK_URL` and `AIOPS_NOTIFICATION_USER_WEBHOOK_URL` via secret references (`notificationDevSecretRef`, `notificationUserSecretRef`) or direct webhook URLs (`notificationDevWebhookUrl`, `notificationUserWebhookUrl`). The legacy `AIOPS_NOTIFICATION_WEBHOOK_URL` environment variable has been removed.

## Technical Design Decisions

- **Dual-Channel Support**: Supports both secretKeyRef and direct string webhook URL parameters in Helm values for flexibility across GitOps overlays.
- **Backwards Schema Compatibility**: Added schema definitions for `notificationDevSecretRef`, `notificationUserSecretRef`, `notificationDevWebhookUrl`, and `notificationUserWebhookUrl` in `values.schema.json`.

## Implementation Details

1. Updated `templates/aiops.yaml` to render `AIOPS_NOTIFICATION_DEV_WEBHOOK_URL` and `AIOPS_NOTIFICATION_USER_WEBHOOK_URL` based on `notificationDevSecretRef`/`notificationDevWebhookUrl` and `notificationUserSecretRef`/`notificationUserWebhookUrl`. Removed `AIOPS_NOTIFICATION_WEBHOOK_URL`.
2. Updated `values.yaml` to replace `notificationSecretRef` with default empty dev and user notification settings.
3. Updated `values-aiops.yaml` and `values-aiops-live-approved.yaml` with the configured dev and user Discord webhook endpoints.
4. Updated `values.schema.json` with JSON schema validation rules for the new notification parameters.
5. Updated `README.md` documentation.

## Files Changed

**Templates:**
* `templates/aiops.yaml` — Replaced `AIOPS_NOTIFICATION_WEBHOOK_URL` with dev and user notification webhook environment variables.

**Configuration:**
* `values.yaml` — Replaced `notificationSecretRef` with dev and user notification keys.
* `values-aiops.yaml` — Configured dev and user Discord webhook URLs.
* `values-aiops-live-approved.yaml` — Updated notification config to use dev and user webhook URLs.
* `values.schema.json` — Added JSON schema properties for dev and user notification keys. Change trail exception for `techx-corp-chart/values.schema.json`: JSON format does not support comments.

**Documentation:**
* `README.md` — Updated documentation for dev and user notification settings.
* `docs/changes/2026-07-30-configure-aiops-dev-user-discord-webhooks.md` — This change record.

## Dependencies and Cross-Repository Impact

None. The `aiops` Python runtime already supports `AIOPS_NOTIFICATION_DEV_WEBHOOK_URL` and `AIOPS_NOTIFICATION_USER_WEBHOOK_URL` in `aiops/integrations/notification.py`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | `NotificationClient` in `aiops` now routes incident notifications concurrently to the dedicated dev and user Discord webhooks. |
| **Infrastructure** | No infrastructure changes. |
| **Deployment** | Argo CD reconciles the updated deployment manifest and environment variables upon git sync. |
| **Performance** | Multi-channel dispatch runs concurrently via `ThreadPoolExecutor`. |
| **Security** | Webhook URLs are managed in chart overlays or secret references. |
| **Reliability** | Isolate dev channel technical traces from user-facing summaries. |
| **Cost** | No cost impact. |
| **Backward compatibility** | Legacy `AIOPS_NOTIFICATION_WEBHOOK_URL` removed; superseded by dev and user webhook channels. |
| **Observability** | No change to metric names. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm template | `helm template techx-corp . -f values-aiops.yaml` | ✅ Pass |
| Schema validation | `helm lint . -f values-aiops.yaml` | ✅ Pass |

### Manual Verification

Verified rendered deployment YAML contains `AIOPS_NOTIFICATION_DEV_WEBHOOK_URL` and `AIOPS_NOTIFICATION_USER_WEBHOOK_URL` and no `AIOPS_NOTIFICATION_WEBHOOK_URL`.

## Migration or Deployment Notes

Argo CD will automatically apply the updated Deployment manifest upon Git push.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Invalid webhook URL string | Low | Low | Revert git commit to revert manifest. |

**Rollback procedure:**

Revert the commit in `techx-corp-chart`.

<!-- Change trail: @hungxqt - 2026-07-30 - Document configuration of dev and user Discord webhooks for aiops runtime. -->
