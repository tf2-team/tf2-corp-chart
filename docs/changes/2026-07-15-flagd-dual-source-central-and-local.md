# Change: flagd dual source (local file + BTC central HTTP)

## Summary

Production flagd now loads feature flags from **both** the chart-local `flagd/demo.flagd.json` ConfigMap file and the BTC central HTTP `flags.json`. flagd merge order puts **HTTP last**, so BTC always wins on duplicate flag keys while team-only keys can live only in the local file.

## Context

* Previously prod used a single HTTP source (`values-prod.yaml` / `values-flagd-sync.yaml`), so TF-owned experimental flags required either redefining everything centrally or abandoning the local ConfigMap.
* flagd natively supports multiple `--sources`; merge priority is **last source wins** on key clash ([flagd sync merge](https://flagd.dev/concepts/syncs/)).
* BTC chaos/incident flags (`paymentFailure`, `cartFailure`, …) must remain authoritative and must not be bypassed by local UI or file overrides for the same keys.

## Before

* Base `values.yaml`: `--uri file:./etc/flagd/demo.flagd.json` (+ flagd-ui sidecar).
* Prod / `values-flagd-sync.yaml`: single HTTP source only; `sidecarContainers: []`.
* Local ConfigMap was still mounted via init copy, but flagd did not read it in prod.

## After

* Base `values.yaml`: unchanged runtime (local file only); comment notes prod dual-source overlays.
* Prod and `values-flagd-sync.yaml` use:

  ```text
  --sources
  [
    {"uri":"/etc/flagd/demo.flagd.json","provider":"file"},
    {"uri":"https://…/flags.json","provider":"http","authHeader":"Bearer …"}
  ]
  ```

* **file first, HTTP last** → central definitions override the same keys from local.
* flagd-ui remains disabled in prod (no cluster UI writing the local file for shared keys).
* Team-only flags: add **unique** keys to `flagd/demo.flagd.json` (Git → ConfigMap → pod restart so init re-copies emptyDir).

## Technical Design Decisions

* **Central wins (HTTP last)** rather than local-last, so a mistaken local copy of a BTC key cannot soft-bypass mentor/chaos control.
* **Keep flagd-ui off in prod** — UI only mutates the file source; with central-last that is safe for shared keys, but disabling UI avoids operator confusion and accidental local-only toggles.
* **No change to base `values.yaml` command** — pure local/Compose installs stay offline-capable without BTC HTTP dependency.
* **Absolute file path** `/etc/flagd/demo.flagd.json` matches the emptyDir mount from base values (more reliable than `./etc/...` under `--sources`).
* Alternatives rejected:
  * Local-last merge — unsafe for BTC-owned keys.
  * HTTP-only (previous) — blocks TF-only flags without central cooperation.
  * Re-enable flagd-ui — out of scope; can be revisited if team needs live local toggles for unique keys only.

## Implementation Details

1. Updated `components.flagd.command` in `values-prod.yaml` to dual `--sources` (file then HTTP).
2. Aligned `values-flagd-sync.yaml` with the same array and documented merge order.
3. Annotated base `values.yaml` flagd command so operators know where dual-source lives.
4. Adjusted directive-03 evidence checklist to expect dual-source + BTC authority.
5. Left ConfigMap `flagd-config`, init-copy, and emptyDir mount unchanged so the file provider path exists at runtime.

## Files Changed

**Configuration:**

* `values-prod.yaml` — Dual flagd sources; central HTTP last; comments for team-only keys.
* `values-flagd-sync.yaml` — Same dual-source contract for manual `-f` layering.
* `values.yaml` — Comment only (base still local-file-only).

**Documentation:**

* `docs/operations/directive-03-evidence-template.md` — flagd dual-source evidence line.
* `docs/changes/2026-07-15-flagd-dual-source-central-and-local.md` — this change record.

## Dependencies and Cross-Repository Impact

None required in platform or infra.

* Runtime still depends on BTC HTTP reachability from the cluster for central flags (same as before).
* Local file source depends on existing chart ConfigMap `flagd-config` and initContainer copy (already in base chart).
* Related ops tooling: workspace `scripts/monitor-feature-flags.*` can still poll central URL or `-File` / `-FromCluster` separately; not updated in this change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Services still resolve flags via in-cluster flagd RPC/OFREP. Shared keys follow BTC; new local-only keys become available after ConfigMap + flagd restart. |
| **Infrastructure** | No new cloud resources. flagd continues HTTP poll to BTC endpoint. |
| **Deployment** | GitOps values-only change; Argo sync rolls flagd Deployment command args. |
| **Security** | Same bearer as before; no new secrets. flagd-ui remains off in prod. |
| **Reliability** | If BTC HTTP is down, flagd behavior depends on flagd HTTP-source failure mode (flags already loaded may remain; new polls fail). Local file still supplies non-overridden keys. |
| **Backward compatibility** | Compatible for consumers; effective flag set may grow with local-only keys. Shared keys still match central when present. |
| **Observability** | No new metrics; existing flagd OTEL exporters unchanged. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (prod layer) | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Pass (0 failed; icon INFO only) |
| Helm template (flagd command) | `helm template ...` filter `flagd-build` / dual URI | Pass — file then HTTP in `command` |

### Manual Verification

* After Argo sync: `kubectl -n techx-corp-prod get deploy flagd -o jsonpath="{.spec.template.spec.containers[0].args}"` (or `command`) shows both file and HTTP source entries, HTTP last.
* Confirm BTC chaos flag still evaluates from central when ON (e.g. known mentor window) and is not stuck on local default.
* Optional: add a unique test key only in `flagd/demo.flagd.json`, restart flagd, evaluate via OFREP/RPC.

### Remaining Verification (Post-Merge)

* Operator: Argo sync prod Application `techx-corp` and wait for flagd Ready.
* Smoke: storefront browse/checkout with flags OFF baseline.

## Migration or Deployment Notes

1. Merge chart PR to `main` (prod Application tracks `main`).
2. Argo auto-sync updates flagd Deployment; pods roll.
3. No secrets-chart or infra apply required.
4. To add a **team-only** flag:
   1. Edit `flagd/demo.flagd.json` with a **new** key name (do not reuse BTC keys).
   2. Commit/merge chart.
   3. After ConfigMap sync, restart flagd pods so init re-copies the file into the emptyDir (file provider then loads the new key).
5. Do **not** redefine BTC chaos keys in local JSON expecting to override them — central wins.

```cmd
cd /d techx-corp-chart
helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml
helm template techx-corp . -n techx-corp-prod ^
  -f values.yaml -f values-public-alb.yaml -f values-prod.yaml ^
  | findstr /i "sources demo.flagd flags.json"
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Local JSON invalid breaks file source startup | Low | Medium | Validate JSON before merge; base demo file already schema-valid |
| Operators expect local file to override BTC | Medium | Low | Documented central-last order; flagd-ui remains off |
| Team reuses BTC key names in local file | Medium | Low | Local values ignored for those keys; no incident bypass |
| Dual source increases config complexity | Low | Low | Same pattern as official flagd multi-source docs |

**Rollback procedure:**

1. Revert this commit (or restore previous single-HTTP `--sources` in `values-prod.yaml` / `values-flagd-sync.yaml`).
2. Merge to `main`; Argo syncs flagd back to central-only.

<!-- Change trail: @hungxqt - 2026-07-15 - Dual flagd sources: local file + BTC HTTP (central wins). -->
