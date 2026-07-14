# Change: Chart support for Argo CD internal path (`/argocd`)

## Summary

Wired frontend-proxy environment and NetworkPolicy egress so Envoy can reach Argo CD in the `argocd` namespace at path `/argocd`, matching operator access via `https://internal.hungtran.id.vn/argocd/`. Documented preferred UI access in the GitOps runbook.

## Context

Infra exposes Argo CD with `server.rootpath=/argocd` and plain HTTP. Platform Envoy routes `/argocd/` to the Argo CD Service. The chart must inject the cross-namespace host/port and keep emergency ALB blocked-prefix lists aligned with CloudFront.

## Before

* frontend-proxy env had no `ARGOCD_*` variables.
* Emergency `publicAlb.blockedPrefixes` omitted `/argocd`.
* GitOps runbook only documented port-forward on `:443`.
* NetworkPolicy frontend-proxy egress had no rule to `argocd` NS (policy currently disabled by default).

## After

* `ARGOCD_HOST=argocd-server.argocd.svc.cluster.local`, `ARGOCD_PORT=80`.
* `blockedPrefixes` includes `/argocd`.
* NetworkPolicy (when enabled) allows frontend-proxy → argocd-server TCP/80.
* Runbook: private DNS URL **and** localhost port-forward on `:80` at `/argocd/` (both supported).

## Technical Design Decisions

* **Cross-namespace FQDN Service DNS** rather than a same-namespace ExternalName: keeps chart values simple and matches Envoy STRICT_DNS.
* **Egress rule ready while NetworkPolicy is off:** avoids a future surprise when `networkPolicy.enabled` flips to true.
* **No second Ingress** in the chart for Argo CD (ownership stays in infra module; path stays on frontend-proxy).

## Implementation Details

1. `values.yaml` frontend-proxy env + blockedPrefixes.
2. `values-public-alb.yaml` comments for CF block list and `/argocd`.
3. `templates/networkpolicy.yaml` egress to `argocd` namespace.
4. `docs/operations/gitops-argocd.md` access section rewrite.

## Files Changed

**Configuration:**
* `values.yaml` — ARGOCD env, blockedPrefixes.
* `values-public-alb.yaml` — operator comments.

**Templates:**
* `templates/networkpolicy.yaml` — frontend-proxy egress to argocd-server.

**Documentation:**
* `docs/operations/gitops-argocd.md`
* `docs/changes/2026-07-14-argocd-internal-url-path.md` — this change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-platform:** frontend-proxy image must include Envoy `/argocd` routes (promote `default.image.tag` after bake).
* **techx-corp-infra:** Argo CD Helm values for rootpath/insecure/url + CloudFront `/argocd` block.
* Related: `techx-corp-infra/docs/changes/2026-07-14-argocd-internal-url-path.md`, platform `docs/changes/2026-07-14-frontend-proxy-argocd-route.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | After new frontend-proxy image: `/argocd/` works on internal ALB |
| **Deployment** | Argo sync for chart; image tag must include Envoy change |
| **Security** | No public Argo Ingress; CF still blocks `/argocd` |
| **NetworkPolicy** | Additive egress only when policies enabled |
| **Backward compatibility** | Additive |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Helm lint (optional) | `helm lint . -f values.yaml -f values-public-alb.yaml -f values-prod.yaml` | Operator post-merge |

### Manual Verification

* After image + infra: VPN browse `https://internal.hungtran.id.vn/argocd/`.
* Confirm public shop hostname still 403 on `/argocd/`.

### Remaining Verification (Post-Merge)

* Sync Application; roll frontend-proxy pods on new tag.
* Login smoke + list Applications.

## Migration or Deployment Notes

1. Merge/deploy infra Argo CD rootpath + CF block.
2. Publish platform image with Envoy route; set chart `default.image.tag`.
3. Argo CD auto-sync chart; wait for frontend-proxy rollout.
4. VPN: open `https://internal.hungtran.id.vn/argocd/`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Env present before new image | Low | Low | Old image ignores unused env; route missing until image rolls |
| Wrong Service name labels | Low | Medium | Verify `kubectl -n argocd get svc,pods -l app.kubernetes.io/name=argocd-server` |

**Rollback procedure:** Revert chart commit; redeploy previous image tag if Envoy route must be removed.
