#!/usr/bin/env bash

set -euo pipefail

users="${1:-}"
measurement_minutes="${2:-20}"
warmup_minutes="${3:-5}"

if [[ -z "$users" || ! "$users" =~ ^[0-9]+$ ]]; then
  echo "Usage: bash docs/mandate-16/run-fixed-capacity-load-test.sh <users> [measurement-minutes] [warmup-minutes]" >&2
  exit 1
fi

namespace="techx-corp-prod"
expected_context="arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"
expected_nodes=6
expected_workers=3
run="docs/evidence/mandate-16/tail-latency/${users}-users-run-01-fixed-6-nodes"

mkdir -p "$run"

if [[ -e "$run/start-time.txt" || -e "$run/end-time.txt" ]]; then
  echo "Refusing to overwrite an existing run: $run" >&2
  exit 1
fi

: > "$run/warmup-monitor.log"
: > "$run/measurement-monitor.log"

current_context="$(kubectl config current-context)"
node_count="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
karpenter_replicas="$(kubectl get deployment karpenter -n kube-system -o jsonpath='{.spec.replicas}')"
worker_ready="$(kubectl get deployment load-generator-worker -n "$namespace" -o jsonpath='{.status.readyReplicas}')"
worker_desired="$(kubectl get deployment load-generator-worker -n "$namespace" -o jsonpath='{.spec.replicas}')"

echo "=== PRE-FLIGHT ==="
echo "Context: $current_context"
echo "Nodes: $node_count"
echo "Karpenter replicas: $karpenter_replicas"
echo "Locust workers: $worker_ready/$worker_desired"

if [[ "$current_context" != "$expected_context" ]]; then
  echo "ERROR: unexpected Kubernetes context" >&2
  exit 1
fi

if [[ "$node_count" -ne "$expected_nodes" ]]; then
  echo "ERROR: expected $expected_nodes nodes, found $node_count" >&2
  exit 1
fi

if [[ "$karpenter_replicas" -ne 0 ]]; then
  echo "ERROR: Karpenter must remain at zero replicas" >&2
  exit 1
fi

if [[ "$worker_ready" -ne "$expected_workers" || "$worker_desired" -ne "$expected_workers" ]]; then
  echo "ERROR: Locust workers must be $expected_workers/$expected_workers" >&2
  exit 1
fi

initial_bad_pods="$(kubectl get pods -n "$namespace" --no-headers | grep -E 'Pending|OOMKilled|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError' || true)"
if [[ -n "$initial_bad_pods" ]]; then
  echo "ERROR: initial state is not clean:" >&2
  echo "$initial_bad_pods" >&2
  exit 1
fi

echo
echo "In Locust: NEW -> Users=$users -> Spawn rate=10 -> START"
read -r -p "Press Enter only when Locust shows exactly $users users and $expected_workers workers..."

echo "Starting ${warmup_minutes}-minute warm-up..."
for minute in $(seq 1 "$warmup_minutes"); do
  sleep 60
  {
    echo
    echo "=== WARM-UP $minute/$warmup_minutes - $(date -Iseconds) ==="
    kubectl get pods -n "$namespace" | grep -E 'NAME|Pending|OOMKilled|CrashLoopBackOff' || true
  } | tee -a "$run/warmup-monitor.log"
done

echo
echo "Capture Locust while RUNNING and save it as:"
echo "$run/00-locust-running-${users}-users.png"
read -r -p "After taking the screenshot, RESET Locust statistics and press Enter..."

date -Iseconds | tee "$run/start-time.txt"
bash docs/mandate-16/capture-cluster-state.sh "$run/cluster-start.txt"

echo "Starting ${measurement_minutes}-minute measurement..."
break_early=0

for minute in $(seq 1 "$measurement_minutes"); do
  sleep 60

  {
    echo
    echo "=== MINUTE $minute/$measurement_minutes - $(date -Iseconds) ==="
    echo "Nodes: $(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
    echo
    echo "--- HPA ---"
    kubectl get hpa -n "$namespace"
    echo
    echo "--- Non-healthy pods ---"
    kubectl get pods -n "$namespace" | grep -Ev 'NAME|Running|Completed' || true
    echo
    echo "--- Node usage ---"
    kubectl top nodes
  } | tee -a "$run/measurement-monitor.log"

  fatal_pods="$(kubectl get pods -n "$namespace" --no-headers | grep -E 'OOMKilled|CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerError' || true)"
  if [[ -n "$fatal_pods" ]]; then
    echo "BREAKPOINT: fatal pod state detected:" | tee -a "$run/measurement-monitor.log"
    echo "$fatal_pods" | tee -a "$run/measurement-monitor.log"
    break_early=1
    break
  fi

  if [[ "$minute" -eq $((measurement_minutes - 1)) ]]; then
    echo "One minute remaining. Prepare to STOP Locust."
  fi
done

if [[ "$break_early" -eq 1 ]]; then
  echo "Measurement stopped early because of a fatal pod state."
else
  echo "Measurement duration completed."
fi

read -r -p "STOP Locust now, then immediately press Enter..."
date -Iseconds | tee "$run/end-time.txt"
bash docs/mandate-16/capture-cluster-state.sh "$run/cluster-end.txt"

echo
echo "Cluster evidence saved to: $run"
echo "Before RESET, save Locust statistics, charts, failures, CSV, and the two exact-window Grafana screenshots."

