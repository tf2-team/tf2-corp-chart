# Change: `local-*` flag twins in chart flagd ConfigMap

## Summary

Chart `flagd/demo.flagd.json` now includes `local-<name>` twins of every demo chaos flag for team UI self-test under dual-source flagd (BTC HTTP last on original keys). Ops comments in prod flagd values point operators at `local-*` toggles.

## Context

* Prod flagd dual-sources local file + BTC HTTP; original keys follow BTC.
* Platform apps dual-consume original + `local-*` (OR / max). Chart ConfigMap must expose the twins for file provider + flagd-ui.

## Before

* ConfigMap flags matched BTC-style original keys only (plus offline defaults).

## After

* Same 15 original keys plus 15 `local-*` twins (default OFF, `(team local)` descriptions).
* `values-prod.yaml` / `values-flagd-sync.yaml` comments document `local-*` self-test path.

## Technical Design Decisions

* Keep JSON in sync with `techx-corp-platform/src/flagd/demo.flagd.json`.
* Do not change dual-source order (BTC still wins on original key names).
* Do not put `local-*` on BTC central document.

## Implementation Details

1. Updated `flagd/demo.flagd.json` with `local-*` entries.
2. Documented team toggle path in flagd values comments.

## Files Changed

* `flagd/demo.flagd.json` — `local-*` twins.
* `values-prod.yaml` — comment: toggle `local-*` via `/feature`.
* `values-flagd-sync.yaml` — same.
* `docs/changes/2026-07-15-local-prefix-feature-flags.md` — this record.

Change trail exception for `flagd/demo.flagd.json`: JSON does not support comments. Attribution @hungxqt.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-platform/docs/changes/2026-07-15-local-prefix-feature-flags.md`.
* Cluster effect requires platform images that dual-read `local-*` flags.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change until apps dual-read and are redeployed |
| **Deployment** | flagd ConfigMap update; may need flagd pod restart for init-copy emptyDir |
| **Security** | No change |
| **Backward compatibility** | New keys only; originals unchanged |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint prod | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Pass |
| Flag JSON sync | platform `src/flagd` vs chart `flagd` | Pass (equal, 15 local-*) |

### Manual Verification

* After sync: ConfigMap `flagd-config` contains `local-paymentFailure` etc.
* With dual-consume apps: UI toggle `local-*` injects; original UI toggle under dual-source still non-authoritative.

### Remaining Verification (Post-Merge)

* Argo sync + flagd restart if emptyDir not refreshed; smoke with platform dual-read images.

## Migration or Deployment Notes

1. Merge chart; Argo syncs ConfigMap.
2. Restart flagd pods so init re-copies JSON into emptyDir (UI/file provider).
3. Deploy platform dual-read images before expecting `local-*` runtime effect.
4. Operators: use **`local-*`** in `/feature` for team self-test.

```cmd
cd /d techx-corp-chart
helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Flag schema without app dual-read is inert | Low | Low | Promote apps same window |
| UI still lists original keys | Medium | Low | Ops note to use local-* |

**Rollback procedure:** Revert `flagd/demo.flagd.json` and comments; Argo sync + flagd restart.

<!-- Change trail: @hungxqt - 2026-07-15 - local-* flag twins in chart ConfigMap for team self-test. -->
