# Mandate 17 evidence index

## Implementation baseline

- Platform merge: `ba6dd5b` (PR #54, contains `78b671f`)
- Platform test completion merge: `f3c2aa6` (PR #59, contains `61db75f`)
- Chart identity/AZ merge: `5025ada` (PR #178, contains `f508baa`)
- Infra CNI merge: `d6ddda3` (PR #102)
- Chart containment/production revision: `48ff38f` (PR #187)
- Implementation date: 2026-07-21
- Platform branch: `mandate-17/optional-dependency-resilience`
- Chart branch: `mandate-17/identity-az-resilience`
- Infra Plan 2 branch: `mandate-17/vpc-cni-network-policy`
- Chart Plan 2 branch: `mandate-17/network-containment`

The read-only production preflight and open resilience gates are recorded in
[resilience.md](resilience.md).

## Local verification completed

| Check | Command | Result |
|---|---|---|
| Optional dependency tests | `npm run test:resilience` from `src/frontend` | 10/10 helper, gateway and API-route tests pass |
| Frontend type/build | `npx tsc --noEmit` and `npm run build` | Pass; Next production build compiled |
| Secure delivery scripts | `check_pinned_base_images.py`, `check_release_catalog.py`, `test_secure_delivery_scripts.py` | Pass |
| Helm/schema | `helm lint . -f values-prod.yaml` | Pass |
| Directive 3 | `scripts/verify-directive-03.ps1` | Pass |
| Mandate 5 regression | `scripts/verify-runtime-hardening.ps1` | Local render/schema contracts pass |
| Identity inventory | `scripts/mandate17-inventory.ps1 -KubeContext techx-tf2-prod` | 21 rendered and live identity/token/RBAC checks pass |
| Containment render | `tests/mandate17/verify-rendered-manifests.ps1` | Disabled, ingress-only, full enforcement, proxy and attacker contracts pass |

The repository's existing `npm run lint` command is not a valid Next.js 16
command (`next lint` was removed), and the legacy `.eslintrc` is incompatible
with ESLint 9. This pre-existing tooling issue must be fixed separately; the
Mandate 17 change does not modify CI or lint configuration.

## Pending after merge and rollout

- [ ] Platform CI, Semgrep, Trivy, image signing, SBOM, and attestation pass.
- [x] Immutable frontend image `sha-ba6dd5b` and ECR digest recorded in `resilience.md`.
- [x] Chart promotes that immutable image and Argo CD is `Synced/Healthy` at `48ff38f`.
- [x] Live inventory passes and dangerous `auth can-i` checks return `no` for 21 workloads.
- [ ] IRSA smoke tests pass for checkout, product-reviews, and shopping-copilot.
- [ ] Ad dependency fault returns HTTP 200 empty data with
      `X-TechX-Degraded-Dependencies: ad` and p95 below 750 ms.
- [ ] AZ fault keeps browse/cart/checkout SLO and all cordoned nodes are restored.
- [ ] Storefront exposure, operational endpoints, observability, and flagd checks pass.
- [ ] Infra CNI NetworkPolicy change is applied in `standard` mode while Chart policy is disabled.
- [ ] Ingress-only activation passes positive traffic and SLO checks.
- [ ] Full activation has healthy PolicyEndpoints and proxy metrics.
- [ ] Attacker test passes DNS and blocks lateral movement, Kubernetes API,
      managed data planes, proxy access, and arbitrary internet.

## Approved live commands

Run only during an approved window with a named rollback operator:

```powershell
$ctx = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
./scripts/mandate17-inventory.ps1 -KubeContext $ctx
./scripts/mandate17-coredns-readiness.ps1 -KubeContext $ctx
# Review the generated placement evidence and surviving-zone capacity first.
./scripts/mandate17-coredns-readiness.ps1 -KubeContext $ctx -CapacityApproved -Execute
./scripts/mandate17-dependency-chaos.ps1 -KubeContext $ctx -Dependency ad -ProbeUri "<storefront>/api/data"
./scripts/mandate17-az-chaos.ps1 -KubeContext $ctx -Zone us-east-1a -CapacityApproved -Execute
```

The CoreDNS script deletes at most one ready replica and waits for full
Deployment recovery. It does not automatically retry when the replacement is
still placed on the wrong node or zone. Do not proceed to AZ chaos unless its
final output reports `ready=True`, two distinct nodes, and two distinct zones.

Do not run dependency and AZ faults at the same time. Capture Locust,
Prometheus/Grafana, Pod placement, Argo health, flagd checks, and rollback output
for the exact fault window.
