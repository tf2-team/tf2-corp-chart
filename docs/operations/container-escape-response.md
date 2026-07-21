# Container Escape Response

Use this runbook when a workload uses `privileged`, host namespaces, hostPath, or any signal suggests node compromise.

## First Response

1. Preserve evidence before changing the node.
2. Identify the Pod, namespace, node, service account, image and actor from EKS audit logs.
3. Cordon the node if capacity and SLO allow it.
4. Inspect co-located workloads and any mounted service-account tokens or Secrets.
5. Review CloudTrail for unusual AWS API calls by the node IAM role.
6. Drain and replace the node after evidence capture. Treat the old node as untrusted.
7. Rotate affected workload credentials and review lateral movement.
8. Confirm runtime-hardening admission denies the same manifest and the inventory scanner returns clean.

## Useful Commands

```powershell
kubectl get pod -A -o wide | sls '<node-name>'
kubectl describe node <node-name>
kubectl -n <namespace> get pod <pod-name> -o yaml
kubectl -n <namespace> logs <pod-name> --all-containers --timestamps
kubectl cordon <node-name>
```

Do not rely on deleting the Pod alone after host access was achieved. Once a Pod has host-level access, the worker node and any credentials reachable from it must be treated as compromised until replaced or rotated through the approved incident process.
