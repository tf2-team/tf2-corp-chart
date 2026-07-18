# Native runtime-hardening operations

## Phase 1: verify source

Run static checks without touching a cluster:

```powershell
pwsh scripts/verify-runtime-hardening.ps1
kubectl kustomize gitops/runtime-hardening/base
kubectl kustomize gitops/runtime-hardening/overlays/audit
kubectl kustomize gitops/runtime-hardening/overlays/enforce
```

Native admission tests require a disposable Kubernetes cluster and `yq` v4:

```powershell
pwsh scripts/verify-runtime-hardening.ps1 -KubeContext kind-runtime-hardening
```

Do not point this test command at production. The script installs enforce
bindings and creates a temporary valid Pod for the UPDATE denial case.

## Phase 2: audit alongside Gatekeeper

The production Application initially sources the audit overlay. Gatekeeper stays
at `deny` so there is no admission gap.

```powershell
argocd app sync runtime-hardening
argocd app wait runtime-hardening --sync --health --timeout 300

kubectl get validatingadmissionpolicies
kubectl get validatingadmissionpolicybindings `
  -o custom-columns=NAME:.metadata.name,POLICY:.spec.policyName,ACTIONS:.spec.validationActions

pwsh scripts/audit-runtime-hardening.ps1 `
  -KubeContext arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod
```

Every VAP must report its current `observedGeneration` with no
`status.typeChecking.expressionWarnings`. If the API server publishes an
`Accepted` condition, it must be `True`. The three bindings must contain only
`Warn,Audit`. Observe at least one normal deployment change window and retain
warning/audit output. VAP audit evaluates new admission requests; the inventory
script is the required check for objects that already exist.

After changing bindings, poll the live binding list and allow admission cache
propagation before collecting evidence. An immediately following request can
briefly observe the previous binding action.

Do not promote while Argo is unhealthy, any workload is unavailable, inventory
is nonzero, or storefront/private operations/flagd/SLO checks are incomplete.

## Phase 3: enforce and prove

Use a reviewed PR to change `runtime-hardening-application.yaml` from
`overlays/audit` to `overlays/enforce`, then sync and verify all binding actions
are exactly `Deny`.

Temporarily move the three Gatekeeper Constraints to `dryrun` during the evidence
window so the denial source is unambiguous:

```powershell
kubectl patch k8scontainerhardening container-hardening --type merge `
  -p '{"spec":{"enforcementAction":"dryrun"}}'
kubectl patch k8sallowedimagetags allowed-image-tags --type merge `
  -p '{"spec":{"enforcementAction":"dryrun"}}'
kubectl patch k8srequiredresources required-resources --type merge `
  -p '{"spec":{"enforcementAction":"dryrun"}}'

kubectl apply -f tests/runtime-hardening/fixtures/invalid-root.yaml
kubectl apply -f tests/runtime-hardening/fixtures/invalid-uid-zero.yaml
kubectl apply -f tests/runtime-hardening/fixtures/invalid-capability.yaml
kubectl apply -f tests/runtime-hardening/fixtures/invalid-latest-deployment.yaml
kubectl apply -f tests/runtime-hardening/fixtures/invalid-resources-job.yaml
kubectl apply -f tests/runtime-hardening/fixtures/valid-pod.yaml
kubectl apply -f tests/runtime-hardening/fixtures/update-latest-pod.yaml
kubectl delete -f tests/runtime-hardening/fixtures/valid-pod.yaml --ignore-not-found
```

Invalid output must name `ValidatingAdmissionPolicy` and the runtime-hardening
policy/binding. It must not name the Gatekeeper webhook. Re-run inventory, Argo
health, endpoint smoke tests, flagd behavior, and SLO checks before retirement.

## Phase 4: retire Gatekeeper

Retirement requires a change window and an approved backup of exact Gatekeeper
manifests. First merge a PR that disables automated sync/self-heal on the
Gatekeeper controller Application; root-prod must reconcile that state.

Cleanup order is mandatory because the Gatekeeper webhook is fail-closed:

1. Confirm all VAP generations are observed with no type-check warnings and all
   bindings are `Deny`.
2. Delete `gatekeeper-validating-webhook-configuration` first.
3. Re-run an invalid fixture and confirm VAP still denies it.
4. Cascade-delete `gatekeeper-policy`, then `gatekeeper`, through Argo CD.
5. Remove leftover Service, Deployments, PDB, Secret, RBAC, and ServiceAccounts.
6. Delete Gatekeeper CRDs only after all custom resources are gone.
7. Delete `gatekeeper-system`.
8. Remove Gatekeeper source files and child manifests from Git; sync root-prod.
9. Remove the temporary `gatekeeper-system` namespace exclusion from VAP bindings.
10. Run final inventory, native denial demo, Argo health, and regressions.

Never delete the Gatekeeper Service/controller while its fail-closed webhook
configuration still exists. Removing a YAML child from Git is insufficient by
itself because root-prod uses `prune: false`.

## False positives

Revert the runtime-hardening Application path from enforce to audit through Git.
Add a fixture reproducing the false positive, fix CEL, and rerun the native test
suite. Exceptions must be narrowly scoped and record owner, reason, expiry, and
Platform Security approval.
