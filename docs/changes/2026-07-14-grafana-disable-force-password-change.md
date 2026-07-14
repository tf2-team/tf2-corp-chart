# Change: Grafana — Disable Forced Initial Admin Password Change

## Summary

Configure the Grafana subchart so operators logging in with the ESO-synced admin credentials are not forced to change the password on first login. Sets `grafana.grafana.ini.security.disable_initial_admin_password_change: true` while keeping admin credentials sourced from Kubernetes Secret `techx-corp-grafana-admin` (SEC-05).

## Context

Grafana prompts for a password change on first login when the initial-admin password-change flow is enabled (and especially when the password is still the default `admin`). This workspace already provisions a non-Git admin password via External Secrets Operator / AWS Secrets Manager into `techx-corp-grafana-admin`. Operators expect that configured password to work without an extra mandatory change step after deploy.

* Needed now for smoother operator login after SEC-02 (login required) and SEC-05 (secret-backed admin password).
* Related: SEC-02 Grafana access hardening backlog; SEC-05 credential removal.

## Before

`values.yaml` Grafana block required login and disabled anonymous access, but did not set `disable_initial_admin_password_change`. Admin credentials came from:

```yaml
grafana:
  admin:
    existingSecret: techx-corp-grafana-admin
    userKey: admin-user
    passwordKey: admin-password
```

First login could still show the forced password-change UI depending on Grafana version and password state.

## After

Same authentication and secret model, plus:

```yaml
grafana:
  grafana.ini:
    security:
      disable_initial_admin_password_change: true
```

Login with the Secret-backed admin user/password no longer requires an immediate password change. Password value still lives only in ASM/ESO → Secret (not in Git).

## Technical Design Decisions

* **Option chosen:** Helm `grafana.ini.security.disable_initial_admin_password_change` (Grafana official setting / env `GF_SECURITY_DISABLE_INITIAL_ADMIN_PASSWORD_CHANGE`).
* **Rejected:** Putting `adminPassword` plaintext back into values (violates SEC-05).
* **Rejected:** Only relying on non-default password without this flag — incomplete; Grafana may still force change in some versions.
* **Constraint:** Effective together with a non-default password in `techx-corp-grafana-admin`; default `admin`/`admin` remains unsafe and is not restored here.
* **Limitation:** Does not rotate or set the password itself; operators must ensure ASM `.../grafana` has a strong `admin-password`.

## Implementation Details

1. Under `grafana.grafana.ini` in `values.yaml`, add `security.disable_initial_admin_password_change: true`.
2. Leave `admin.existingSecret` / keys unchanged so the official Grafana chart still injects admin user and password from Secret.
3. Document operator expectation: after Argo sync / Helm upgrade, restart is unnecessary if ConfigMap/env update rolls the Deployment; otherwise wait for Argo auto-sync.

## Files Changed

**Configuration:**

* `values.yaml` — Set `grafana.grafana.ini.security.disable_initial_admin_password_change: true`.

**Documentation:**

* `docs/changes/2026-07-14-grafana-disable-force-password-change.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Password content remains in AWS Secrets Manager / ESO (chart secrets chart already maps `.../grafana` → `techx-corp-grafana-admin`). No platform or infra code changes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Grafana admin login no longer forces password change on first access when using Secret credentials |
| **Infrastructure** | No change |
| **Deployment** | Helm/Argo upgrade applies new `grafana.ini` fragment; Grafana pod reloads/restarts per chart rollout |
| **Performance** | No change |
| **Security** | Slightly weaker UX control (no forced rotate on first login); mitigated by secret-managed strong password and no anonymous admin (SEC-02) |
| **Reliability** | Improves operator access predictability after deploy |
| **Cost** | No change |
| **Backward compatibility** | Fully backward-compatible; existing Secret contract unchanged |
| **Observability** | No change to dashboards/datasources |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Values fragment present | Grep / visual review of `values.yaml` | ✅ Present |
| Schema | N/A (boolean under free-form `grafana.ini`) | N/A |

### Manual Verification

* Local file review only in this change. Post-merge: log in to Grafana with ASM-synced credentials and confirm no “change password” interstitial.

### Remaining Verification (Post-Merge)

1. Argo CD sync (or Helm upgrade) for the target environment.
2. Confirm Grafana Deployment rolled or ConfigMap mounted with the new setting.
3. Login as admin with password from `techx-corp-grafana-admin` and verify dashboards load without forced password change.
4. Confirm ASM secret `admin-password` is not the default `admin`.

## Migration or Deployment Notes

1. Ensure AWS Secrets Manager secret for Grafana includes strong non-default `admin-user` / `admin-password` (see workspace ESO docs).
2. Sync chart release (Argo preferred):

```cmd
argocd app sync techx-corp
argocd app wait techx-corp --sync --health --timeout 600
```

3. If login still fails due to an old DB password, reset in-cluster:

```cmd
kubectl -n <namespace> exec -it deploy/grafana -- grafana cli admin reset-admin-password <new-password>
```

Keep ASM Secret and reset password in sync after any CLI reset.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operators keep a weak password without forced change | Medium | Medium | Enforce strong password in ASM; rotate via ESO; access only via Client VPN / internal ALB |
| Setting ignored if password still default `admin` | Low | Low | Set non-default password in ASM before relying on this flag |

**Rollback procedure:**

1. Remove `grafana.grafana.ini.security.disable_initial_admin_password_change` (or set to `false`) in `values.yaml`.
2. Commit, sync Argo CD / Helm upgrade.
3. Grafana returns to default first-login password-change behavior.
