# Mandate 17 evidence index

## Implementation baseline

- Platform baseline: `ac10d15`
- Chart baseline: `cff9931`
- Implementation date: 2026-07-21
- Platform branch: `mandate-17/optional-dependency-resilience`
- Chart branch: `mandate-17/identity-az-resilience`

Replace baseline values with merged commit SHAs and exact Argo target revision
before running live tests.

## Local verification completed

| Check | Command | Result |
|---|---|---|
| Optional dependency unit test | `node --experimental-strip-types --test utils/resilience/OptionalDependency.test.mjs` from `src/frontend` | 4/4 pass |
| Frontend type/build | `npx tsc --noEmit` and `npm run build` | Pass; Next production build compiled |
| Secure delivery scripts | `check_pinned_base_images.py`, `check_release_catalog.py`, `test_secure_delivery_scripts.py` | Pass |
| Helm/schema | `helm lint . -f values-prod.yaml` | Pass |
| Directive 3 | `scripts/verify-directive-03.ps1` | Pass |
| Mandate 5 regression | `scripts/verify-runtime-hardening.ps1` | Local render/schema contracts pass |
| Identity inventory | `scripts/mandate17-inventory.ps1` | 21 rendered first-party workloads pass |

The repository's existing `npm run lint` command is not a valid Next.js 16
command (`next lint` was removed), and the legacy `.eslintrc` is incompatible
with ESLint 9. This pre-existing tooling issue must be fixed separately; the
Mandate 17 change does not modify CI or lint configuration.

## Pending after merge and rollout

- [ ] Platform CI, Semgrep, Trivy, image signing, SBOM, and attestation pass.
- [ ] Immutable frontend image tag/digest recorded here.
- [ ] Chart promotes that immutable image and Argo CD is `Synced/Healthy`.
- [ ] Live inventory passes with `-KubeContext` and dangerous `auth can-i` checks return `no`.
- [ ] IRSA smoke tests pass for checkout, product-reviews, and shopping-copilot.
- [ ] Ad dependency fault returns HTTP 200 empty data with
      `X-TechX-Degraded-Dependencies: ad` and p95 below 750 ms.
- [ ] AZ fault keeps browse/cart/checkout SLO and all cordoned nodes are restored.
- [ ] Storefront exposure, operational endpoints, observability, and flagd checks pass.

## Approved live commands

Run only during an approved window with a named rollback operator:

```powershell
$ctx = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
./scripts/mandate17-inventory.ps1 -KubeContext $ctx
./scripts/mandate17-dependency-chaos.ps1 -KubeContext $ctx -Dependency ad -ProbeUri "<storefront>/api/data"
./scripts/mandate17-az-chaos.ps1 -KubeContext $ctx -Zone us-east-1a -CapacityApproved -Execute
```

Do not run dependency and AZ faults at the same time. Capture Locust,
Prometheus/Grafana, Pod placement, Argo health, flagd checks, and rollback output
for the exact fault window.
