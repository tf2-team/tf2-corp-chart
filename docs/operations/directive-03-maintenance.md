# Directive #3: Zero-downtime maintenance runbook

This runbook is the production acceptance procedure for **Directive #3 -
maintenance during operating hours**. It validates the public money flow while a
stateless node is drained or a Deployment is restarted.

The acceptance SLOs are:

| Flow | SLO |
|---|---:|
| Browse | success rate >= 99.5% |
| Cart | success rate >= 99.5% |
| Checkout | success rate >= 99% |
| Public storefront | p95 < 1 second |

## Safety boundary

This change removes single-pod failure from the **stateless** money-flow tier by
setting a production floor of two replicas, rendering PodDisruptionBudgets and
retaining readiness probes plus `maxUnavailable: 0` rolling updates.

It does **not** turn a singleton stateful application into a cluster. Kafka and
`valkey-cart` are still stateful singletons until their replication, quorum,
failover and data migration are designed and tested. Therefore:

- Do not select a node hosting Kafka or `valkey-cart` for the first mentor drain.
- Do not use `kubectl drain --force` or `--disable-eviction`.
- Do not claim that the stateful tier has no single point of failure.
- Open a separate architecture/change record before draining a stateful node.

This is a release gate, not a reason to hide the residual risk.

## Controls delivered by the chart

- Production minimum of two replicas for stateless services used by browse,
  cart and checkout.
- `PodDisruptionBudget` with `minAvailable: 1` for every enabled, multi-replica
  stateless Deployment (fixed replicas and HPA-backed replicas).
- Readiness probes keep an unready replacement out of Service endpoints.
- Rolling deployments keep `maxUnavailable: 0` and `maxSurge: 1`.
- Soft zone and host spreading prefers different failure domains while still
  permitting scheduling when one zone has no spare capacity.
- Grafana dashboard **Directive #3 - Maintenance SLO** displays the four SLOs,
  Ready pods, Ready endpoints and pod-to-node placement.
- `scripts/maintenance-load-test.js` drives the public storefront and enforces
  the same thresholds in k6.

Flag definitions and the incident mechanism remain unchanged.

## Change window roles

Assign these roles before the call:

| Role | Responsibility |
|---|---|
| Incident commander | Starts/stops the exercise and owns the abort decision |
| Kubernetes operator | Cordon, drain and uncordon only the approved node |
| SLO observer | Watches Grafana and k6 thresholds continuously |
| Evidence recorder | Records UTC timestamps, Git/Argo revision and mentor confirmation |

The Kubernetes operator must not also be the sole SLO observer.

## 1. Pre-flight gate

Run these commands from the production context and save the output:

```bash
kubectl config current-context

kubectl get application techx-corp -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

kubectl get nodes \
  -L topology.kubernetes.io/zone,workload-class,karpenter.sh/capacity-type

kubectl get deploy,hpa,pdb -n techx-corp-prod
kubectl get pods -n techx-corp-prod -o wide
kubectl get endpointslice -n techx-corp-prod
kubectl get events -n techx-corp-prod --sort-by=.lastTimestamp
```

Proceed only if all of the following are true:

- Argo CD is `Synced` and `Healthy` at the reviewed Git revision.
- Every critical stateless Deployment has at least two Ready replicas.
- Every rendered PDB shows `ALLOWED DISRUPTIONS >= 1` before the drain.
- No critical pod is Pending, CrashLooping or NotReady.
- The cluster has schedulable headroom for replacement pods.
- The chosen node does not host Kafka, `valkey-cart`, PostgreSQL or OpenSearch.
- Storefront and operational-access requirements from Directive #1 are still met.

Select and inspect the candidate node:

```bash
NODE=<reviewed-stateless-node>

kubectl get pods -A --field-selector spec.nodeName="$NODE" -o wide
kubectl get node "$NODE" \
  -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,CLASS:.metadata.labels.workload-class,CAPACITY:.metadata.labels.karpenter\.sh/capacity-type
```

Stop if the node selection violates the safety boundary.

## 2. Start external traffic and monitoring

Run k6 from a machine outside EKS through the **public storefront URL**. Do not
use port-forwarding or the internal ALB because that would bypass the customer
path.

```bash
BASE_URL=https://<PUBLIC_STOREFRONT_HOST> \
DURATION=20m RATE=2 \
k6 run --summary-export=directive-03-k6-summary.json \
  scripts/maintenance-load-test.js | tee directive-03-k6.log
```

In Grafana, open **Dashboards -> Directive #3 - Maintenance SLO**, set the time
range to the last 15 minutes and keep auto-refresh at 5 seconds. Establish at
least five minutes of green baseline before maintenance begins.

Record:

- test start time in UTC;
- public storefront URL (never credentials);
- Git commit and Argo revision;
- baseline success rates and p95;
- candidate node and all pods initially on that node.

## 3. Execute one controlled disruption

Mentor and incident commander must explicitly approve the candidate node before
the operator runs these commands:

```bash
kubectl cordon "$NODE"

kubectl drain "$NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=10m
```

Do not add `--force` or `--disable-eviction`. A PDB blocking eviction is a safety
signal; investigate it instead of bypassing it.

During the drain, keep these watches open in separate terminals:

```bash
kubectl get pods -n techx-corp-prod -o wide --watch
```

```bash
kubectl get pdb -n techx-corp-prod --watch
```

```bash
kubectl get endpointslice -n techx-corp-prod --watch
```

The expected behavior is:

1. One replica remains Ready and continues receiving traffic.
2. The evicted pod is recreated on another eligible node.
3. The replacement enters Service endpoints only after its readiness probe passes.
4. k6 and all four Grafana SLO panels remain within threshold.

## 4. Abort and recovery

Abort immediately when any of these occurs:

- checkout success < 99%;
- browse or cart success < 99.5%;
- storefront p95 >= 1 second;
- a critical Service has zero Ready endpoints;
- replacement pods remain Pending or the drain times out;
- an unexpected stateful pod is selected for eviction.

Recovery:

```bash
kubectl uncordon "$NODE"
kubectl get pods -n techx-corp-prod -o wide
kubectl get endpointslice -n techx-corp-prod
```

If the disruption was a rollout rather than a node drain, stop the rollout and
roll back the reviewed Git change through the normal Argo CD workflow. Do not
make an untracked live patch that Git will immediately overwrite.

## 5. Complete the exercise

After the drain finishes, keep traffic running for at least five stable minutes,
then restore the node:

```bash
kubectl uncordon "$NODE"
kubectl get nodes
kubectl get pods -n techx-corp-prod -o wide
kubectl get pdb -n techx-corp-prod
kubectl get application techx-corp -n argocd \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision
```

The k6 process must exit with status `0`; otherwise at least one SLO threshold
failed and the exercise is not accepted.

## Audit evidence to attach

- Approved maintenance window and mentor name.
- PR URL, merge commit, Argo revision and `Synced/Healthy` output.
- Candidate node, pod inventory before/after, drain and uncordon timestamps.
- `kubectl get deploy,hpa,pdb`, pod placement and EndpointSlice output.
- Grafana screenshots covering baseline, drain and recovery.
- `directive-03-k6-summary.json`, k6 log and exit code.
- Any alert, SLO breach, abort or rollback with its timeline.
- Mentor confirmation.
- Residual-risk owner and follow-up for Kafka/`valkey-cart` HA.

The directive is complete only after the mentor observes the controlled
maintenance and confirms that all required SLOs stayed within threshold.
