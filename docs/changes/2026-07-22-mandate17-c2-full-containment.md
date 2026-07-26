# Mandate 17 C2 Full Containment

## Change

- Enable production egress enforcement after the C1 ingress-only gate passed.
- Enable the two-replica Envoy egress proxy and route approved external callers through it.
- Configure Grafana proxy variables while preserving in-cluster traffic through `NO_PROXY`.

## Validation

- Run Helm lint and the Mandate 17 three-state manifest verifier before merge.
- After Argo CD sync, require all PolicyEndpoints, both proxy replicas on separate nodes/AZs, and a Healthy application.
- Run positive storefront, IRSA, observability, flagd, and exposure checks before the attacker test.

## Rollback

Rollback C2 to the C1 state in one PR by setting `networkPolicy.enforceEgress=false` and `egressProxy.enabled=false` while keeping `networkPolicy.enabled=true`. Only set `networkPolicy.enabled=false` if ingress containment must also be reverted. Do not add arbitrary egress exceptions.
