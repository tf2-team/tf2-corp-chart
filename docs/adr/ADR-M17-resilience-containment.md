# ADR-M17: Chịu lỗi và khoanh vùng runtime

- Trạng thái: Đề xuất
- Ngày: 2026-07-21
- Platform owner: pending approval
- CDO reviewer: pending approval
- Rollback operator: pending assignment

## Bối cảnh

Storefront phụ thuộc vào `ad` và `recommendation` để hiển thị nội dung tùy chọn. Khi một dependency tùy chọn bị chậm hoặc không sẵn sàng, lỗi đó không được làm hỏng luồng browse, cart hoặc checkout. Hệ thống phải degrade có kiểm soát thay vì để lỗi lan ngược lên storefront.

Production cluster đang trải trên hai Availability Zone. Nếu lập lịch theo zone quá cứng, khi một zone mất khả dụng thì Pod thay thế có thể không schedule được sang zone còn lại. Vì vậy Mandate 17 cần cân bằng giữa việc trải workload qua AZ và khả năng recover khi một AZ bị mất.

Các workload ứng dụng trước đây có nguy cơ dùng chung Kubernetes ServiceAccount hoặc được mount default API token trong khi phần lớn không cần gọi Kubernetes API. Điều này làm tăng tác động lateral movement nếu một pod ứng dụng bị compromise.

## Quyết định

1. Các frontend gRPC call tới `ad` và `recommendation` dùng deadline có thể cấu hình, mặc định 500 ms. Chỉ các lỗi deadline, unavailable và lỗi kết nối tương đương mới được fallback về HTTP 200 với danh sách rỗng.
2. Response fallback gắn header `X-TechX-Degraded-Dependencies`, ghi structured log và gắn active-span attributes để quan sát được trạng thái degraded. Lỗi lập trình và lỗi schema vẫn đi theo error path bình thường, không bị che bởi fallback.
3. Mỗi first-party chart component có một ServiceAccount riêng theo tên component. ServiceAccount và Pod đều đặt `automountServiceAccountToken: false`. Các IRSA annotation hiện có vẫn được giữ cho `checkout`, `product-reviews` và `shopping-copilot`.
4. Zone topology spread dùng `ScheduleAnyway` để Pod có thể recover sang AZ còn lại khi một AZ mất khả dụng. Hostname topology spread vẫn dùng `DoNotSchedule` để tránh dồn nhiều replica lên cùng một node.
5. Không chỉnh, không disable và không thay đổi cơ chế sự cố/feature flag của `flagd`. Source, key, provider, port, singleton placement và incident behavior của `flagd` được giữ nguyên. `flagd` chỉ được đưa vào baseline/recovery check để chứng minh hệ thống không làm hỏng cơ chế này.
6. NetworkPolicy có ba trạng thái rollout: disabled, ingress-only và full ingress/egress enforcement. AWS VPC CNI giữ `standard` mode trong phạm vi Mandate 17.
7. External HTTPS cho các caller được phê duyệt đi qua Envoy CONNECT proxy hai replica với hostname allowlist. Application pod không được egress trực tiếp ra Internet; `flagd` vẫn giữ đúng path BTC provider hiện có.
8. Attacker fixture là một Deployment đã harden, không có Kubernetes token và chỉ có DNS egress cần thiết. Attacker pod không được truy cập application services, Kubernetes API, managed data planes, proxy hoặc Internet tùy tiện.

## An toàn và rollout

- Merge và validate fallback của platform trước khi promote immutable image.
- Rollout identity và AZ scheduling trước khi kích hoạt NetworkPolicy.
- Áp dụng CNI support khi application policy đang disabled, sau đó bật ingress-only trước khi bật full egress containment.
- Chỉ chạy fault khi Argo CD đang `Synced/Healthy`, error budget còn đủ và không có incident đang mở.
- Chạy dependency chaos và AZ chaos ở hai cửa sổ riêng, dưới continuous load; không chạy đồng thời.
- Chaos script phải capture initial state và restore replica/node trong `finally`.
- Không chạy live chaos nếu chưa có named operator và rollback operator approval.

## Kiểm chứng

- Frontend test bao phủ timeout parsing và phân biệt lỗi degradable/non-degradable.
- Helm lint, Mandate 5 verification, Directive 3 verification và Mandate 17 identity inventory phải pass.
- Dependency fault pass khi có HTTP 200 empty fallback, degraded header và p95 của endpoint bị ảnh hưởng nằm dưới ngưỡng chấp nhận.
- AZ fault pass khi browse/cart/checkout giữ SLO và node được uncordon hoặc recovery được ghi nhận rõ ràng.
- IRSA, observability, storefront exposure và `flagd` phải tiếp tục hoạt động.
- Static verification phải chứng minh ingress-only không render egress isolation, và trong full mode chỉ proxy nắm giữ rule internet CIDR.

## Rollback

- Revert frontend image về immutable digest trước đó nếu fallback gây lỗi.
- Revert chart revision nếu identity hoặc scheduling làm hỏng workload. Không cấp RBAC rộng như một cách rollback nhanh.
- Dependency script restore lại replica count ban đầu.
- AZ script uncordon mọi node mà nó đã cordon, kể cả khi script lỗi giữa chừng.
- Rollback NetworkPolicy theo thứ tự `true/true -> true/false -> false/false`; rollback CNI là bước cuối và chỉ làm sau khi application policy đã disabled.

## Hệ quả

Optional dependency failure trở thành degraded có quan sát được thay vì làm storefront failure. Pod ứng dụng bị compromise không mặc định nhận Kubernetes API token. Workload có thể schedule/recover sang AZ còn lại khi một AZ mất khả dụng, trong khi hard hostname spread vẫn tránh việc dồn replica lên cùng một node. Vì vậy capacity preflight là điều kiện bắt buộc trước khi chạy AZ chaos.
