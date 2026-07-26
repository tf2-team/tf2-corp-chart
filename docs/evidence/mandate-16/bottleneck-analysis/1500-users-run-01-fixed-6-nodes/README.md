# MANDATE-16.2 Evidence - 1500 Users

| File | Root duration | Finding |
|---|---:|---|
| `01-jaeger-checkout-trace-01.png` | 3.35 s | Frontend Checkout 1.56 s; Checkout client 524.39 ms và server 166.72 ms |
| `02-jaeger-checkout-trace-02.png` | 10.92 s | Checkout server 536.91 ms; prepare order 467.13 ms |
| `03-jaeger-checkout-trace-03.png` | 3.03 s | Checkout client 426.88 ms và server 72.33 ms |
| `04-jaeger-checkout-trace-04.png` | 6.24 s | Checkout client 457.28 ms và server 218.26 ms |
| `05-jaeger-checkout-trace-05.png` | 3.13 s | Prepare order 443.92 ms; Currency client 380.81 ms |

Pattern chung là client/queue wait và prepare-order fan-out.
