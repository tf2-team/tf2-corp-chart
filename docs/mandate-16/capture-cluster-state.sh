#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: bash docs/mandate-16/capture-cluster-state.sh <output-file>" >&2
  exit 1
fi

output_file="$1"
namespace="techx-corp-prod"
expected_context="arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
current_context="$(kubectl config current-context)"

if [[ "$current_context" != "$expected_context" ]]; then
  echo "Refusing capture: current context is $current_context" >&2
  echo "Expected: $expected_context" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_file")"

{
  echo "Captured: $(date -Iseconds)"
  echo "Context: $current_context"
  echo
  echo "=== Karpenter ==="
  kubectl get deployment karpenter -n kube-system
  echo
  echo "=== Nodes ==="
  kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
  echo
  echo "=== Node usage ==="
  kubectl top nodes
  echo
  echo "=== Deployments ==="
  kubectl get deployment -n "$namespace"
  echo
  echo "=== HPA ==="
  kubectl get hpa -n "$namespace"
  echo
  echo "=== Pods ==="
  kubectl get pods -n "$namespace" -o wide
  echo
  echo "=== Pod usage ==="
  kubectl top pods -n "$namespace" --containers
  echo
  echo "=== Recent events ==="
  kubectl get events -n "$namespace" --sort-by=.lastTimestamp
} > "$output_file"

echo "Saved cluster state to $output_file"
