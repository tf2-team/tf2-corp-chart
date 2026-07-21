# MANDATE-16.1 evidence

Official baseline methodology: fixed six-node cluster, Karpenter paused, three fixed Locust workers, application HPA enabled.

Run directories:

- `pre-test-fixed-6-nodes`: cluster state before the test sequence.
- `200-users-run-01-fixed-6-nodes`: first official run.
- Add `300-users-run-01-fixed-6-nodes`, `400-users-run-01-fixed-6-nodes`, and higher load levels only after each preceding run is valid.

Do not mix evidence from runs that used different node counts or a different number of Locust workers.
