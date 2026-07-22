# Mandate 17 C2 managed Kafka egress

## Scope

Align the production VPC egress rules for the four approved Amazon MSK clients
with the live SASL/SCRAM listener on TCP 9096:

- checkout outbox publisher;
- accounting outbox reconciler;
- fraud-detection consumer;
- OpenTelemetry collector Kafka metrics receiver.

The existing TCP 9092 rules remain restricted to the in-cluster Kafka pod for
non-production compatibility. No other workload receives MSK access.

No CIDR, image, Service, RBAC, flagd, application, exposure or replica change
is included.

## Live evidence

After C2 activation, checkout and OTel collector logged timeouts to private MSK
broker IPs on TCP 9096. Their PolicyEndpoints allowed the production VPC only
on TCP 9092. Checkout requests recovered after the outbox endpoint remediation,
but background Kafka publication remained blocked and could accumulate backlog.

## Verification

Run the standard production lint, Mandate 17 rendered verifier, runtime
hardening verifier and 21-workload identity inventory. After merge, wait for
Argo CD `Synced/Healthy`, confirm the four PolicyEndpoints contain VPC TCP 9096,
verify outbox/collector Kafka timeout logs stop, and restart the clean 15-minute
positive SLO window before any attacker test.

## Rollback

Revert this PR through GitOps. Do not patch live policy or broaden VPC ports.
