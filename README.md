# TechX Corp Platform - Helm Chart

Helm chart to deploy the TechX Corp platform on Kubernetes: application
microservices, AI review service + LLM, and the bundled observability stack
(collector, metrics, logs, traces, dashboards).

## Install

**Preferred (GitOps / Argo CD):** see [`docs/operations/gitops-argocd.md`](docs/operations/gitops-argocd.md) and `gitops/clusters/`.  
Env overlays: `values-dev.yaml`, `values-prod.yaml` (plus `values-public-alb.yaml`).

**Break-glass Helm** (disable Argo auto-sync first after cutover):

```sh
helm upgrade --install techx-corp ./ -n techx-corp-prod --create-namespace \
  -f values-public-alb.yaml -f values-prod.yaml
```

## AIOps Runtime

The AIOps workload is disabled in base values. After publishing the image,
enable `values-aiops.yaml`; secure delivery writes the immutable
`aiops.image.digest` into that overlay. Repository/tag remain available only
for a reviewed break-glass deployment. The opt-in workload includes an
internal Service, readiness/liveness probes, Prometheus scrape annotations,
read-only Kubernetes RBAC, and a persistent volume for incident and audit
state. It intentionally runs one replica with a non-overlapping rollout because
the current store is SQLite.

Sensitive `AIOPS_*` values must come from the ESO-managed
`techx-corp-aiops-grafana-webhook` Secret referenced by `aiops.existingSecret`.
The runtime is exposed only inside the cluster as `aiops-runtime:8080`, backed
by the FastAPI container on port 8000. The default policy remains `dry-run`;
switching to live remediation is a separate operational approval. Grafana's
single notification-policy tree keeps the existing Discord route and mirrors
warning, critical, SEV1, and SEV2 alerts to the separate AIOps contact point.

## ALB-Backed Public Ingress for frontend-proxy

An opt-in public ALB-backed Ingress is available to expose the storefront while securing administrative/telemetry interfaces.

### Prerequisites

Ensure the AWS Load Balancer Controller is installed in your EKS cluster:

1. **Create the IAM Role and Policy (IRSA)**: Run `terraform apply` in the `techx-corp-infra` folder to provision the controller's IAM role.
2. **Install the AWS Load Balancer Controller via Helm** (prefer Terraform output so `region` + `vpcId` + IRSA are set — avoids IMDS hop-limit CrashLoop):
   ```sh
   helm repo add eks https://aws.github.io/eks-charts
   helm repo update
   # Preferred: values filled by Terraform
   terraform -chdir=../techx-corp-infra/environments/production \
     output -raw aws_load_balancer_controller_helm_command
   # Run the printed command. Manual equivalent:
   helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=<cluster-name> \
     --set region=us-east-1 \
     --set vpcId=vpc-xxxxxxxx \
     --set serviceAccount.create=true \
     --set serviceAccount.name=aws-load-balancer-controller \
     --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<alb-controller-role-arn>
   ```

### Deploying the Public Ingress Overlay

To deploy the chart with public ALB enabled, supply the `values-public-alb.yaml` overlay:

```sh
helm upgrade --install techx-corp ./ -n techx-tf2 -f values-public-alb.yaml --create-namespace
```

### Verification

1. **Verify the Ingress receives a public DNS host**:
   ```sh
   kubectl -n techx-tf2 get ingress frontend-proxy-public
   ```
   *Note: It may take 2-5 minutes for the AWS ALB to provision and register.*

2. **Test Blocked Subpaths (403 Expected)**:
   ```sh
   curl -i http://<ALB_DNS_NAME>/grafana
   curl -i http://<ALB_DNS_NAME>/jaeger
   curl -i http://<ALB_DNS_NAME>/loadgen
   ```
   *All should return an HTTP 403 Forbidden response.*

3. **Test Storefront Paths (200 Expected)**:
   ```sh
   curl -i http://<ALB_DNS_NAME>/
   curl -i http://<ALB_DNS_NAME>/images/logo.png
   ```

## SEC-04: Security Context Hardening

This chart has been hardened to conform to restricted Pod Security Standards. For detailed information, see [SEC-04-notes.md](file:///E:/code-folder/xbrain_projects/phase3/techx-corp-chart/SEC-04-notes.md).

### Documented Exceptions to `readOnlyRootFilesystem: true`
- **postgresql**: Requires writing to state/database files.
- **kafka**: Requires persistence logs.
- **valkey-cart**: Valkey cache database dump persistence.
- **opensearch**: Java process temp, locking, and indexes.

## License
Apache License 2.0.

