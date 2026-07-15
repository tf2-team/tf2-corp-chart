# Directive #3 acceptance evidence

## Change window

- Date/time (UTC):
- Mentor:
- Incident commander:
- Kubernetes operator:
- SLO observer:
- Evidence recorder:
- Public storefront host:
- Git commit:
- Argo CD revision:
- Argo CD sync/health:

## Pre-flight

- [ ] Production manifest policy script passed.
- [ ] Argo CD is `Synced` and `Healthy` at the reviewed revision.
- [ ] All critical Deployments have at least two Ready replicas.
- [ ] All critical HPA floors are two.
- [ ] Every critical PDB allows at least one disruption.
- [ ] Critical replicas occupy distinct nodes and both configured zones.
- [ ] No critical pod is Pending, CrashLooping or NotReady.
- [ ] Replacement capacity/headroom is available.
- [ ] Managed Valkey has a healthy primary and replica in distinct AZs.
- [ ] Candidate node contains no Kafka, PostgreSQL or OpenSearch pod.
- [ ] Directive #1 public/private access boundary is unchanged.
- [ ] flagd is enabled, Ready, and dual-sourced (local file + reviewed BTC HTTP; central wins on key clash).

Attach outputs:

```text
kubectl get application techx-corp -n argocd ...
kubectl get nodes ...
kubectl get deploy,hpa,pdb -n techx-corp-prod
kubectl get pods -n techx-corp-prod -o wide
kubectl get endpointslice -n techx-corp-prod
kubectl get pods -A --field-selector spec.nodeName=<NODE> -o wide
```

## Baseline

- k6 start (UTC):
- Maintenance dashboard interval:
- Browse success:
- Cart success:
- Checkout success:
- Storefront p95:
- Baseline screenshot/link:

## Controlled disruption

- Candidate node:
- Mentor approval time (UTC):
- Cordon time (UTC):
- Drain start/end (UTC):
- Replacement pod Ready time(s):
- Minimum Ready endpoints observed per critical service:
- SLO screenshot/link during drain:
- Alerts or anomalies:

## Recovery and result

- Uncordon time (UTC):
- Five-minute post-maintenance observation completed:
- Browse success:
- Cart success:
- Checkout success:
- Storefront p95:
- k6 exit code:
- k6 summary/log attachment:
- Final pod/PDB/EndpointSlice attachment:
- Result: PASS / ABORT / FAIL
- Mentor confirmation:

Acceptance is PASS only when checkout is at least 99%, browse/cart are at least
99.5%, storefront p95 is below one second, k6 exits zero, and no critical
service reaches zero Ready endpoints.

## Residual risk and follow-up

- Kafka stop/recovery test and outbox drain evidence:
- Managed Valkey failover test:
- Any incident/change ticket:

<!-- Change trail: @hungxqt - 2026-07-15 - flagd dual-source evidence checklist. -->
