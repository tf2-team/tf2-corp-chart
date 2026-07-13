# SEC-05 — Kubernetes NetworkPolicy for east-west traffic restriction

**Date:** 2026-07-13
**Status:** Accepted
**Deciders:** Platform Team
**Priority:** P2

---

## Context

The TechX Corp platform runs ~20 microservices in a single Kubernetes namespace
(`techx-corp`). Without NetworkPolicy, every pod can reach every other pod on any port —
a default that Kubernetes intentionally ships with because not all CNI plugins can enforce
policies.

In the current setup:

- `checkout` can directly connect to `postgresql` even though it has no business reason to.
- A compromised `load-generator` or `ad` pod could attempt connections to `kafka` or `valkey-cart`.
- There is no network-level boundary between stateless app pods and stateful data-plane pods.

The threat model is: **a single compromised or misconfigured pod should not be able to reach
arbitrary other services**. Lateral movement requires either a policy gap or a vulnerability
in a pod that legitimately has access — not a trivially open network.

This ADR covers the decision of *how* to restrict that traffic, not *whether* to (that is
already accepted as part of the SEC-05 security track).

---

## Decision

Implement Kubernetes `NetworkPolicy` objects rendered from the Helm chart, controlled by
`networkPolicy.enabled` in `values.yaml`.

The design follows three principles:

1. **Default deny ingress** — a namespace-scoped `podSelector: {}` policy with `policyTypes: [Ingress]` blocks all unspecified inbound traffic. Egress is not default-denied (see consequences).
2. **Explicit allow per service** — each service gets its own `NetworkPolicy` that lists exactly which pods may call it (ingress) and which pods it may call (egress). The allowed set is derived from the actual environment variables in `values.yaml` (e.g. `CART_ADDR`, `KAFKA_ADDR`).
3. **Opt-in via feature flag** — `networkPolicy.enabled: false` by default so the feature can be safely rolled out through a phased audit → dev soak → prod promotion workflow without requiring a CNI migration gate.

### Pod selector strategy

All first-party pods carry the label `opentelemetry.io/name: <component-name>` (set by
`_helpers.tpl` `selectorLabels`). Policies use this label for precise pod-to-pod matching.

Subchart pods (prometheus, grafana, jaeger) use their own `app.kubernetes.io/name` labels
as set by the upstream Helm charts.

The `otel-collector` DaemonSet is matched by `app.kubernetes.io/component: otel-collector`
(set by the upstream OTel Helm chart).

### Egress default-deny decision

Egress is **not** default-denied at this stage. Reasons:

- Prometheus requires egress to every pod it scrapes; enumerating all scrape targets is brittle.
- `initContainers` using `busybox nc` for wait-for-* readiness checks need egress to data-plane pods before those pods' policies are fully evaluated by some CNI implementations.
- The incremental blast-radius reduction from ingress-only default-deny already covers the primary threat: a compromised pod being *reachable from* other pods that shouldn't talk to it.

Egress default-deny is tracked as a follow-up hardening step once the ingress posture is
proven stable in production.

---

## Alternatives considered

### A — Service mesh (Istio / Linkerd) mTLS + AuthorizationPolicy

Provides stronger identity guarantees (SPIFFE/SVID, mTLS) and L7 policy, but:

- Adds significant operational complexity (sidecar injection, certificate rotation, CRDs).
- Requires cluster-wide installation, which is out of scope for a Helm chart change.
- Overkill for the current threat model; L4 NetworkPolicy achieves the main goal.

Rejected for now. Service mesh remains a valid longer-term goal.

### B — Calico GlobalNetworkPolicy / Cilium CiliumNetworkPolicy

CNI-specific CRDs offer richer semantics (CIDR-based, DNS-based, L7 HTTP rules), but:

- Tie the chart to a specific CNI, breaking portability (AWS VPC CNI, Calico, Cilium are all in use across customer clusters).
- Standard `networking.k8s.io/v1` NetworkPolicy is portable and sufficient for L4 pod-to-pod control.

Rejected in favour of the portable standard API.

### C — Separate NetworkPolicy chart / repository

Keeping policies in a dedicated chart decouples their lifecycle from the application chart,
but:

- Creates a deploy-ordering dependency (policies must land before app pods).
- Splits the traffic matrix across two repositories, making it harder to keep in sync when services are added or removed.
- The `networkPolicy.enabled` flag already allows the policies to be deployed independently of enforcement (dry-run / audit phase).

Rejected. Co-location in the same chart is the simpler, lower-risk approach.

---

## Consequences

### Positive

- Reduces lateral movement blast radius: a compromised pod can only reach the services it
  is explicitly permitted to call.
- Traffic matrix is codified and version-controlled alongside the service definitions that
  drive it (env vars in `values.yaml`).
- `networkPolicy.enabled: false` default means zero risk to existing deployments until
  the operator consciously opts in.
- Phased rollout (audit → dev soak → prod) limits incident risk during adoption.

### Negative / risks

- **CNI dependency** — policies are silently ignored if the CNI does not enforce them (e.g.
  vanilla Flannel). Operators must verify CNI support before enabling. Documented in
  `docs/operations/network-policy.md`.
- **Policy drift** — if a developer adds a new inter-service call without updating the
  NetworkPolicy template, traffic will be blocked silently in enforced clusters. Mitigated
  by the "Adding a new service" section in the operations doc and future CI linting.
- **Egress not default-denied** — a compromised pod can still initiate connections to
  destinations not covered by its explicit egress rules (e.g. external IPs). Accepted as a
  known gap for this phase; egress default-deny is a follow-up item.
- **Prometheus scrape egress** — the prometheus policy uses `podSelector: {}` for egress
  to keep service discovery working. This is broader than strictly necessary and can be
  tightened later once Prometheus SD label selectors are stable.

---

## Implementation

| Artefact | Location |
|----------|----------|
| NetworkPolicy Helm template | `templates/networkpolicy.yaml` |
| Feature flag | `values.yaml` → `networkPolicy.enabled` |
| Traffic matrix + rollout guide | `docs/operations/network-policy.md` |
| This ADR | `docs/adr/SEC-05-network-policy.md` |

---

## References

- [Kubernetes NetworkPolicy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [AWS VPC CNI Network Policy support](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html)
- SEC-05 backlog item: `docs/backlogs/2026-07-09-sec-05-eso-aws-secrets-manager.md`
- Operations guide: `docs/operations/network-policy.md`
