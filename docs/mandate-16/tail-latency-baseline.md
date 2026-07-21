# MANDATE-16.1 - Tail Latency Baseline

## Phạm vi

| Flow | Measurement boundary |
|---|---|
| Browse | `GET /api/products/{productId}` tại Frontend |
| Cart | `POST /api/cart` tại Frontend |
| Checkout | `POST /api/checkout` tại Frontend |

## Điều kiện test

- Cluster `techx-tf2-prod`, namespace `techx-corp-prod`
- Cố định 6 nodes; Karpenter controller `0/0`
- 3 Locust workers; browser traffic off
- Application HPA bật
- Spawn rate 10 users/second; warm-up 5 phút; measurement khoảng 20 phút

## Ngân sách độ trễ

| Flow | p95 budget | p99 budget |
|---|---:|---:|
| Browse | < 300 ms | < 700 ms |
| Cart | < 300 ms | < 700 ms |
| Checkout | < 500 ms | < 1 s |

## Kết quả

| Users | Duration | Avg RPS | Failures | Browse p95/p99 | Cart p95/p99 | Checkout p95/p99 | Result |
|---:|---:|---:|---:|---:|---:|---:|---|
| 200 | 22m20s | 41.60 | 0 | 6.32 / 34.2 ms | 9.72 / 46.3 ms | 96.1 / 176 ms | Passed |
| 300 | 21m54s | 63.17 | 0 | 7.08 / 39.7 ms | 18.4 / 55.8 ms | 96.9 / 174 ms | Passed; có pod Pending |
| 400 | 27m00s | 84.35 | 0 | 7.92 / 45.4 ms | 17.4 / 49.5 ms | 99.3 / 186 ms | Passed |
| 500 | 28m23s | 104.66 | 0 | 18.0 / 48.1 ms | 24.6 / 53.9 ms | 150 / 227 ms | Passed |
| 600 | 28m04s | 125.56 | 1 | 23.9 / 55.4 ms | 43.4 / 85.7 ms | 156 / 237 ms | Passed |
| 700 | 31m20s | 142.49 | 2 | 30.0 / 66.2 ms | 33.9 / 74.5 ms | 158 / 230 ms | Passed |
| 800 | 28m19s | 167.49 | 1 | 37.7 / 77.6 ms | 38.7 / 85.8 ms | 179 / 322 ms | Passed |
| 1000 | 28m41s | 209.74 | 2 | 45.4 / 89.5 ms | 49.2 / 111 ms | 226 / 382 ms | Passed |
| 1200 | 22m44s | 240.50 | 7 | 97.2 / 186 ms | 195 / 365 ms | 392 / 707 ms | Invalid: concurrent rollout |
| 1500 | 27m53s | 263.13 | 306 | 1.5 / 2.0 s | 2.1 / 2.5 s | 2.9 / 3.6 s | **Breakpoint** |

Mức 900 users không được thực hiện. Run 1200 không được dùng để kết luận vì có rollout đồng thời.

Các run 200-1000 sử dụng rolling p95/p99 lớn nhất trên Grafana trong measurement window. Run 1500 sử dụng percentile tích lũy toàn run từ Locust CSV; Grafana cùng cửa sổ xác nhận Browse `793 ms / 1.15 s`, Cart `1.39 s / 1.87 s` và Checkout `2.60 s / 4.97 s`.

## Breakpoint 1500 users

- 445,957 requests; 306 failures; failure rate 0.0686%.
- Start: 6 nodes Ready; 60 pods Running; 30 Pending.
- End: 5 nodes Ready, 1 NotReady; 52 pods Running; 37 Pending.
- Cả ba flow vượt budget trước khi Spot node chuyển NotReady.
- Spot interruption làm tăng 503/504 ở phần cuối nhưng không tạo ra breakpoint ban đầu.

## Dashboard và evidence

- Dashboard: **Webstore SLOs & Resources**
- UID: `webstore-perf-slo-res`
- URL: https://internal.hungtran.id.vn/grafana/d/webstore-perf-slo-res
- Evidence: `docs/evidence/mandate-16/tail-latency/`
