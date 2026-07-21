# ADR-M17: Resilience and containment

- Status: Proposed
- Date: 2026-07-21
- Platform owner: pending approval
- CDO reviewer: pending approval
- Rollback operator: pending assignment

## Context

The storefront depends on ad and recommendation for optional content. A slow or
unavailable optional dependency must not fail browse, cart, or checkout. The
production cluster also spans two availability zones, but hard zone scheduling
can prevent replacement Pods when one zone is unavailable.

Application workloads currently share a Kubernetes ServiceAccount and receive
the default API token even though they do not call the Kubernetes API. This
increases lateral-movement impact after application compromise.

## Decision

1. Frontend gRPC calls to ad and recommendation use a configurable deadline,
   defaulting to 500 ms. Only deadline, unavailable, and equivalent connection
   errors fall back to HTTP 200 with an empty list.
2. Fallback responses expose `X-TechX-Degraded-Dependencies` and record a
   structured log plus active-span attributes. Programming and schema errors
   continue through the normal error path.
3. Every first-party chart component receives a dedicated ServiceAccount named
   after the component. ServiceAccount and Pod both set
   `automountServiceAccountToken: false`. Existing IRSA annotations remain on
   checkout, product-reviews, and shopping-copilot.
4. Zone topology spread uses `ScheduleAnyway` so Pods can recover in the
   surviving zone. Hostname topology spread remains `DoNotSchedule` to avoid
   co-locating replicas on one node.
5. Flagd source, key, provider, ports, singleton placement, and incident
   behavior are unchanged. NetworkPolicy remains disabled in this change and is
   owned by the containment workstream.

## Safety and rollout

- Merge and validate the platform fallback before promoting its immutable image.
- Roll out identity/AZ changes before any NetworkPolicy activation.
- Require Argo CD `Synced/Healthy`, available error budget, and no open incident.
- Run dependency and AZ chaos as separate windows under continuous load.
- Chaos scripts capture initial state and restore replicas/nodes in `finally`.
- Do not run live chaos without named operator and rollback operator approval.

## Verification

- Frontend test covers timeout parsing and degradable/non-degradable errors.
- Helm lint, Mandate 5 verification, Directive 3 verification, and Mandate 17
  identity inventory must pass.
- Dependency fault requires HTTP 200 empty fallback, degraded header, and p95
  below 750 ms for the affected endpoint.
- AZ fault requires browse/cart/checkout SLO and successful node uncordon.
- IRSA, observability, storefront exposure, and flagd must remain functional.

## Rollback

- Revert the frontend image to the previous immutable digest if fallback fails.
- Revert the chart revision if identity or scheduling breaks a workload. Do not
  grant broad RBAC as a rollback shortcut.
- The dependency script restores the original replica count.
- The AZ script uncordons every node it cordoned, including on failure.

## Consequences

Optional dependency failures become visible degradation instead of storefront
failure. Application compromise no longer receives a Kubernetes API token by
default. Surviving-zone scheduling becomes possible, while hard hostname spread
may still leave a replica Pending if only one suitable node remains; capacity is
therefore a mandatory chaos preflight.
