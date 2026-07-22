# Mandate 17 C2 egress runtime activation

## Scope

- Align workload OTLP egress destinations with the `otel-collector` Service
  selector so AWS VPC CNI compiles both the ClusterIP and pod target endpoints.
- Add a deterministic pod-template checksum for the Envoy static allowlist so
  a ConfigMap value change rolls the two proxy replicas.
- Add rendered-manifest regression coverage for both invariants.

No CIDR, image, Service, RBAC, flagd, application, exposure, replica or
allowlist-domain change is included.

## Live symptoms addressed

- OTLP clients timed out against Service ClusterIP `172.20.224.42:4317` even
  though collector pod IPs existed in PolicyEndpoint.
- The DynamoDB account endpoint was present in the live ConfigMap, but the
  long-running Envoy processes had loaded the previous static config and
  returned HTTP 404 for checkout outbox requests.

## Verification

Run:

```powershell
helm lint . -f values-prod.yaml
.\tests\mandate17\verify-rendered-manifests.ps1
.\scripts\verify-runtime-hardening.ps1
.\scripts\mandate17-inventory.ps1
```

After merge, wait for Argo CD `Synced/Healthy` at the merge revision. Confirm
the proxy rolls to two Ready replicas on separate nodes, workload
PolicyEndpoints include the OTEL Service ClusterIP on TCP 4317/4318, checkout
outbox no longer receives proxy 404, and the official positive matrix plus a
clean 15-minute SLO window pass before running the attacker test.

## Rollback

Revert this PR through GitOps. Do not patch the live NetworkPolicy or restart
pods manually. If checkout or observability regresses, stop Gate 4 and follow
the existing C2 rollback sequence.
