# Runtime hardening operations

## Health and audit

```bash
argocd app get gatekeeper
kubectl -n gatekeeper-system get deploy,pod,pdb,svc,endpoints
kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration \
  -o jsonpath='{.webhooks[*].failurePolicy}'
kubectl get constrainttemplates
kubectl get k8scontainerhardening container-hardening -o yaml
kubectl get k8sallowedimagetags allowed-image-tags -o yaml
kubectl get k8srequiredresources required-resources -o yaml
```

Wait for at least two audit intervals. Every constraint must report
`status.totalViolations: 0` before enforcement.

## Cutover

Gatekeeper is installed only from this repository; no Terraform apply is part of
the runtime-hardening rollout. Bootstrap the controller chart first and wait for
it to become healthy:

```bash
kubectl apply -f gitops/clusters/prod/gatekeeper-appproject.yaml
kubectl apply -f gitops/clusters/prod/gatekeeper-application.yaml
argocd app wait gatekeeper --sync --health --timeout 600
kubectl -n gatekeeper-system rollout status deployment/gatekeeper-controller-manager --timeout=10m
kubectl -n gatekeeper-system rollout status deployment/gatekeeper-audit --timeout=10m
```

Then render the reviewed policy revision to a temporary `dryrun` manifest. Apply
that output, wait for two clean audit cycles, and retain its checksum as evidence.

```powershell
pwsh scripts/render-gatekeeper-dryrun.ps1 -OutputPath gatekeeper-dryrun.yaml
kubectl apply -f gatekeeper-dryrun.yaml
Get-FileHash gatekeeper-dryrun.yaml -Algorithm SHA256
```

After Platform Security approval, bootstrap the policy Application from the same
chart revision:

```bash
kubectl apply -f gitops/clusters/prod/gatekeeper-policy-application.yaml
argocd app wait gatekeeper-policy --sync --health --timeout 600
```

Argo CD applies the committed final state `deny`; no additional cutover commit
is required. Do not change namespace exclusions during cutover.

## Mentor demo

Apply the fixtures that violate root/non-root, image pinning, and resources. A
denial must name the constraint and violated field. Apply `valid-pod.yaml` to
confirm a compliant object is admitted, then delete it.

```bash
kubectl apply -f gitops/gatekeeper/tests/fixtures/root-container.yaml
kubectl apply -f gitops/gatekeeper/tests/fixtures/latest-lowercase.yaml
kubectl apply -f gitops/gatekeeper/tests/fixtures/missing-limit-memory.yaml
kubectl apply -f gitops/gatekeeper/tests/fixtures/valid-pod.yaml
kubectl delete -f gitops/gatekeeper/tests/fixtures/valid-pod.yaml --ignore-not-found
```

## False positives and rollback

Capture the rejected object and constraint message, revert the affected
constraint to `dryrun`, and wait for Argo sync. Add a Gator regression case before
re-enabling `deny`. Exceptions require owner, reason, expiry, and approval in the
ADR. Never disable flagd or change public/private routing as a workaround.

For webhook failure, inspect controller readiness, service endpoints, certificate
secret, and webhook configuration. Existing workloads keep running while new
admissions fail closed. A temporary fail-open change is break-glass only and must
be reverted immediately after recovery.
