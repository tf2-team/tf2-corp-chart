# MANDATE-16.2 - Distributed Tracing Bottleneck Analysis

## Kết luận

Tại breakpoint 1500 users, Checkout chậm do hai pattern lặp lại:

1. Frontend chờ lâu khi gọi gRPC `CheckoutService/PlaceOrder`, trong khi Checkout server xử lý ngắn hơn đáng kể.
2. Với đơn nhiều sản phẩm, `prepareOrderItemsAndShippingQuoteFromCart` thực hiện nhiều Product Catalog và Currency call, làm tăng thời gian server-side.

HPA yêu cầu scale-out nhưng replica mới không schedule được. Spot node bị mất ở phần cuối làm 503/504 tăng thêm, nhưng Grafana đã vượt latency budget trước sự kiện này.

## Run được điều tra

| Thuộc tính | Giá trị |
|---|---|
| Load | 1500 users, 3 Locust workers |
| Thời gian | `2026-07-21T10:42:46+07:00` - `11:10:39+07:00` |
| Capacity | 6 nodes lúc bắt đầu; Karpenter `0/0` |
| Checkout p95/p99 | 2.9 s / 3.6 s |
| Cluster start | 60 Running, 30 Pending |
| Cluster end | 52 Running, 37 Pending |

## Năm trace minh chứng

| Evidence | Root task | Root duration | Frontend Checkout | Checkout client | Checkout server | Span nổi bật |
|---|---|---:|---:|---:|---:|---|
| `01-jaeger-checkout-trace-01.png` | `user_checkout_multi` | 3.35 s | 1.56 s | 524.39 ms | 166.72 ms | Client wait lớn hơn server |
| `02-jaeger-checkout-trace-02.png` | `user_checkout_multi` | 10.92 s | 716.83 ms | 540.58 ms | 536.91 ms | Prepare order 467.13 ms |
| `03-jaeger-checkout-trace-03.png` | `user_checkout_single` | 3.03 s | 706.87 ms | 426.88 ms | 72.33 ms | Client wait lớn hơn server |
| `04-jaeger-checkout-trace-04.png` | `user_checkout_multi` | 6.24 s | 1.30 s | 457.28 ms | 218.26 ms | Client wait và prepare order |
| `05-jaeger-checkout-trace-05.png` | `user_checkout_single` | 3.13 s | 681.22 ms | 516.88 ms | 491.00 ms | Prepare order 443.92 ms; Currency client 380.81 ms |

Root task của Locust không được dùng làm Checkout API latency vì nó chứa thêm request ngoài nhánh `/api/checkout`.

## Phân tích nguyên nhân

### Scale-out không tạo thêm serving capacity

- Có 30 pod Pending lúc bắt đầu và 37 pod Pending lúc kết thúc.
- HPA từng ghi nhận Cart `146%/70%`, Checkout `320%/70%` và Frontend `283%/65%`.
- Cuối run, Cart chỉ `2/8`, Checkout `2/12` và Frontend `2/17` Ready/desired.
- Ba trace có Checkout client span dài hơn server span khoảng 239-358 ms, phù hợp với connection/queue wait trước server handler.

### Fan-out trong Checkout và Frontend

`src/checkout/main.go` gọi Product Catalog và Currency khi chuẩn bị từng order item. Trace 02 và 05 có prepare-order span khoảng 444-467 ms.

`src/frontend/pages/api/checkout.ts` chờ `CheckoutGateway.placeOrder`, sau đó gọi Product Catalog cho từng item bằng `Promise.all` rồi mới trả HTTP response. Response vẫn phải chờ call chậm nhất và tạo thêm connection pressure.

### Spot interruption

Node `ip-10-0-39-210.ec2.internal` chuyển NotReady sau khoảng phút 13. Đây là yếu tố khuếch đại phần cuối, không phải nguyên nhân đầu tiên của việc vượt budget.

## Giải pháp đề xuất

1. Rightsize requests và sửa node selector, topology spread, anti-affinity để replica HPA schedule được trên capacity hiện có.
2. Thêm gRPC deadline và child span đo connection/queue wait trong Frontend Checkout gateway.
3. Thay Product Catalog/Currency call theo từng item bằng batch API hoặc product snapshot.
4. Giữ On-Demand baseline cho critical services; dùng Spot cho scale-out và bật Karpenter interruption handling.
5. Chuyển Email confirmation khỏi synchronous critical path bằng outbox consumer và idempotency.

## Tiêu chí retest

| Chỉ số | Baseline | Mục tiêu |
|---|---:|---:|
| Checkout p95 | 2.9 s | < 500 ms |
| Checkout p99 | 3.6 s | < 1 s |
| Cart p95/p99 | 2.1 / 2.5 s | < 300 / 700 ms |
| Browse p95/p99 | 1.5 / 2.0 s | < 300 / 700 ms |
| Pending critical replicas | 30 lúc start | 0 |

p99 phải giảm mà node count và tổng tài nguyên không tăng.

## Evidence

`docs/evidence/mandate-16/bottleneck-analysis/1500-users-run-01-fixed-6-nodes/`
