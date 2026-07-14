# Change: Grafana — Remove First-Login Forced Password Change

## Summary

Eliminate Grafana’s first-login change-password interstitial by aligning configuration and operator guidance with Grafana’s real behavior: the UI hardcodes that screen when the typed password is the literal string `admin`. There is no `grafana.ini` / Helm flag that disables it. This change removes the ineffective `disable_initial_admin_password_change` setting, keeps password-policy skip available, and updates ASM examples so `admin-password` is never `"admin"`.

## Context

Operators logging in with the ESO-synced Grafana admin secret were still redirected to “Change password” after first login. An earlier attempt set `grafana.grafana.ini.security.disable_initial_admin_password_change: true`, but that key **does not exist** in Grafana (verified against Grafana 12.3.1 / 13.0.1 `defaults.ini` and source). Grafana ignores unknown keys.

Root cause (Grafana frontend `LoginCtrl.tsx`):

```text
if (formModel.password !== 'admin' || config.ldapEnabled || config.authProxyEnabled) {
  // proceed into app
} else {
  // show change-password view
}
```

* Needed now so cluster login works without a mandatory password change step.
* Related: SEC-02 Grafana access hardening; SEC-05 secret-backed admin password.

## Before

* `values.yaml` set non-existent `security.disable_initial_admin_password_change: true` (no effect).
* Admin credentials still from Secret `techx-corp-grafana-admin` via `admin.existingSecret`.
* Operator docs seeded ASM with `{"admin-user":"admin","admin-password":"admin"}`, which **guarantees** the change-password UI on every login with that password.

## After

* Removed the ineffective `disable_initial_admin_password_change` key.
* Explicit `auth.basic.password_policy: false` so the change-password form still offers **Skip** if password is temporarily still `"admin"`.
* Comments on `admin.existingSecret` document the hard requirement: `admin-password` must not be the string `admin`.
* `docs/operations/external-secrets.md` example secret uses a non-`admin` placeholder and explains why.

Login with a non-`admin` password from ASM/ESO no longer shows the change-password interstitial.

## Technical Design Decisions

* **Chosen:** Treat non-default password (not the literal string `admin`) as the only real fix, because the check is client-side hardcoded in Grafana OSS.
* **Rejected:** Keeping `disable_initial_admin_password_change` — does not exist in Grafana; misleading for operators.
* **Rejected:** Re-introducing plaintext `adminPassword` in values — violates SEC-05.
* **Rejected:** Patching/forking Grafana UI — out of scope and not maintainable.
* **Constraint:** Existing Grafana SQLite/DB users created with password `admin` keep that hash until reset; env/secret password only bootstraps the admin user on **first** creation.
* **Limitation:** If operators intentionally keep password `admin`, Grafana will always show the interstitial (Skip remains available with `password_policy: false`).

## Implementation Details

1. Under `grafana.grafana.ini` in `values.yaml`:
   * Remove `security.disable_initial_admin_password_change`.
   * Set `auth.basic.password_policy: false`.
   * Document the hardcoded `admin` password check in comments.
2. Leave `admin.existingSecret` / key names unchanged (SEC-05 contract).
3. Update ASM seed example so `admin-password` is not `"admin"`.
4. For already-running clusters that still use password `admin`, operators must update ASM and reset the in-cluster admin password (see Migration).

## Files Changed

**Configuration:**

* `values.yaml` — Removed no-op setting; set `auth.basic.password_policy: false`; documented non-`admin` password requirement.

**Documentation:**

* `docs/operations/external-secrets.md` — Grafana ASM example no longer uses `admin-password: admin`.
* `docs/changes/2026-07-14-grafana-disable-force-password-change.md` — This change record (rewritten for the correct fix).

## Dependencies and Cross-Repository Impact

* Related local Docker Compose path: `techx-corp-platform/src/grafana/grafana.ini` sets `admin_password = otel` so local first login also skips the interstitial.
* Related: `techx-corp-platform/docs/changes/2026-07-14-grafana-disable-force-password-change.md`
* Password values remain only in AWS Secrets Manager / ESO (not in Git).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change-password interstitial when admin password ≠ `admin` |
| **Infrastructure** | No change |
| **Deployment** | Helm/Argo applies `grafana.ini` fragment; Grafana pod restarts/rolls as chart does |
| **Performance** | No change |
| **Security** | Requires non-default admin password (stronger than default `admin`); skip remains if policy off |
| **Reliability** | Predictable operator login after deploy |
| **Cost** | No change |
| **Backward compatibility** | Existing DB with password `admin` still shows interstitial until password reset |
| **Observability** | No change to dashboards/datasources |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Fake setting removed | Grep `disable_initial_admin_password_change` under chart | ✅ Absent from values |
| Password policy | Grep `password_policy: false` under `grafana.grafana.ini` | ✅ Present |
| Docs seed | Grep ASM grafana example | ✅ Not `admin-password":"admin"` |

### Manual Verification

* Code review against Grafana 12.3.1 `LoginCtrl.tsx` password === `"admin"` gate.
* Post-merge: log in with non-`admin` ASM password and confirm dashboards load without change-password view.

### Remaining Verification (Post-Merge)

1. Confirm ASM secret `techx-corp/{env}/grafana` `admin-password` is not the string `admin`.
2. Argo CD sync (or Helm upgrade).
3. If interstitial still appears, reset DB password to match ASM (commands below).
4. Login as admin and open a dashboard without forced password change.

## Migration or Deployment Notes

1. **Set a non-`admin` password in AWS Secrets Manager** (required for complete removal of the interstitial):

```cmd
aws secretsmanager put-secret-value --region %AWS_REGION% ^
  --secret-id techx-corp/development/grafana ^
  --secret-string "{\"admin-user\":\"admin\",\"admin-password\":\"<ReplaceWithNonAdminPassword>\"}"
```

Use the production secret id for prod. Wait for ESO to sync Secret `techx-corp-grafana-admin`.

2. **Sync chart release** (Argo preferred):

```cmd
argocd app sync techx-corp
argocd app wait techx-corp --sync --health --timeout 600
```

3. **If Grafana already started with password `admin`**, reset the in-cluster user to the new secret value (GF_SECURITY_ADMIN_PASSWORD only applies on first admin creation):

```cmd
kubectl -n <namespace> exec -it deploy/grafana -- grafana cli admin reset-admin-password <ReplaceWithNonAdminPassword>
```

Keep ASM and the CLI-reset password identical after any reset.

4. Optional: delete Grafana PVC only if a full bootstrap from secret is acceptable (destroys local Grafana state).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operators still use password `admin` in ASM | Medium | Medium | Docs + examples forbid it; reset-admin-password procedure above |
| Existing DB password out of sync with ASM after secret rotate | Medium | High | Always pair ASM update with `grafana cli admin reset-admin-password` |
| Removing fake flag confuses readers of older notes | Low | Low | This change doc supersedes the previous approach |

**Rollback procedure:**

1. Revert `values.yaml` / docs in this repo if needed (no functional reliance on the removed fake key).
2. To restore forced change UX, set ASM `admin-password` back to `admin` (not recommended) and reset the Grafana admin password accordingly.
3. Argo sync / Helm upgrade.

<!-- Change trail: @hungxqt - 2026-07-14 - Rewrite change doc: real fix is non-admin password, not fake ini key. -->
