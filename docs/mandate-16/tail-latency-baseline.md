# Mandate 16.1 — Tail Latency Baseline and Budget

## Dashboard

- Name: Webstore SLOs & Resources
- UID: webstore-perf-slo-res
- URL: https://internal.hungtran.id.vn/grafana/d/webstore-perf-slo-res

## Test configuration

- Cluster: techx-tf2-prod
- Namespace: techx-corp-prod
- Browser traffic: disabled
- Locust workload: default mixed HTTP workload
- Spawn rate: 10 users/second
- Warm-up: 5 minutes
- Measurement duration: 20 minutes per load level
- Test operator: Le Nguyen Nhat Thanh
- Test date: TODO
- Image tag: TODO

## Endpoint definitions

| Flow | Service | Span |
|---|---|---|
| Browse | frontend | GET /api/products/{productId} |
| Cart | frontend | POST /api/cart |
| Checkout | frontend | POST /api/checkout |

## Pre-test state


- Locust users: 0
- Locust RPS: 0
- Running nodes: 7
- On-Demand nodes: 3
- Spot nodes: 4
- Unhealthy pods: 0
- Pod restarts: 0
- Memory observation:
  - ip-10-0-25-86: 105%
  - ip-10-0-32-149: 96%
- Notes: Cluster was allowed to stabilize before testing. Two Spot nodes already had high memory usage before load was applied.

## Proposed latency budget

| Flow | p95 budget | p99 budget | Approval |
|---|---:|---:|---|
| Browse | 300 ms | 700 ms | Proposed |
| Cart | 300 ms | 700 ms | Proposed |
| Checkout | 500 ms | 1000 ms | Proposed |

## Test results

| Users | Duration | Average RPS | Flow | Requests | Failures | p95 | p99 | Nodes min/max | Pods min/max | Result |
|---:|---:|---:|---|---:|---:|---:|---:|---:|---|
| 200 | 20m | TODO | Browse | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 200 | 20m | TODO | Cart | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 200 | 20m | TODO | Checkout | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 300 | 20m | TODO | Browse | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 300 | 20m | TODO | Cart | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 300 | 20m | TODO | Checkout | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 400 | 20m | TODO | Browse | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 400 | 20m | TODO | Cart | TODO | TODO | TODO | TODO | TODO | TODO | TODO |
| 400 | 20m | TODO | Checkout | TODO | TODO | TODO | TODO | TODO | TODO | TODO |

## Breakpoint

- First sustained latency violation: TODO
- Load level: TODO users
- Average RPS: TODO
- Affected flow: TODO
- Observed p95: TODO
- Observed p99: TODO
- Success rate: TODO
- Notes: TODO

## Approval

- Proposed by: Le Nguyen Nhat Thanh
- Reviewed by: TODO
- Status: Proposed
- Approval date: TODO
