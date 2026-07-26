# 500 users - Run 01 - Fixed six nodes

- Status: Ready to execute
- Users: 500
- Spawn rate: 10 users/second
- Warm-up: 5 minutes after Locust reaches 500 users
- Measurement: 20 minutes
- Nodes: fixed at 6
- Karpenter: paused at 0 replicas
- Locust workers: fixed at 3 replicas
- Application HPA: enabled
- Locust statistics: reset immediately after warm-up and before measurement starts
- Stop conditions: repeated HTTP failures, SLO violation, OOMKilled, CrashLoopBackOff, or loss of the fixed load

Evidence files are listed in `docs/mandate-16/tail-latency-baseline.md`.
