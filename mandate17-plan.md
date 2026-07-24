# Mandate 17 — Kế hoạch tối thiểu để hoàn thành

## 1. Mục tiêu bắt buộc của mentor

Nguồn chuẩn là
`mandates/MANDATE-17-resilience-and-containment.md`. Mandate chỉ hoàn thành khi
có bằng chứng live cho bốn kết quả:

1. Một dependency optional chết/chậm nhưng browse → cart → checkout vẫn giữ
   SLO nhờ timeout, fallback và graceful degradation.
2. Mất trọn một AZ nhưng DNS và money path vẫn giữ SLO.
3. NetworkPolicy đang bật và attacker không lateral movement hoặc arbitrary
   egress.
4. ServiceAccount/RBAC/token là least privilege và attacker không dùng được
   Kubernetes API.

Ràng buộc giữ nguyên: không hạ SLO, không đụng flagd; giữ `storefront public`
và `ops private`; không thêm hạ tầng chỉ để lấy evidence và không chạy hai
fault đồng thời.

## 2. Trạng thái authoritative ngày 24/07/2026

### Repository và GitOps

| Thành phần | `origin/main` mới nhất |
|---|---|
| Platform | `e3f6f51` |
| Chart | `d216073` |
| Infra | `5e07b2c` |
| Argo | `techx-corp` `Synced/Healthy` tại `d216073`; `linkerd-cni` đang `Synced/Progressing` do Spot node termination, các application còn lại `Synced/Healthy` |

### Production

- Linkerd blocker đã được team Mandate 16 xử lý ở `d11d7e9`: CNI 1 pod/node,
  heartbeat tắt và exception chỉ áp dụng đúng `linkerd-cni/DaemonSet/linkerd-cni`.
- Inventory Job mới `Complete`, `violationCount=0`; failed history trước
  remediation đã được xóa sau khi có hai lần scan pass liên tiếp.
- Một race node-join đã được phát hiện: workload Pod có thể được schedule vài
  giây trước khi Linkerd CNI ghi chain vào `10-aws.conflist`, làm
  `linkerd-network-validator` CrashLoop. Tám Pod bị kẹt đã được tái tạo sau khi
  CNI Ready và frontend trở lại Available; một node mới kế tiếp tái hiện cùng
  lỗi, xác nhận đây không phải sự cố một lần. Bản local bật Linkerd
  `repairController` chính thức, cấp resources và đặt CNI
  `system-node-critical`; PR #253 đã merge/rollout trên toàn bộ node. Inventory sau rollout
  phát hiện đúng một upstream gap: repair-controller không khai báo
  `runAsNonRoot`; remediation local chỉ thêm một exception tuple
  `repair-controller/NON_ROOT`, không miễn các rule khác; PR #255 đã merge.
  Hai inventory Job mới nhất đã `Complete`, `violationCount=0`.
- Snapshot lúc `16:44 +07` ngày 24/07 có 13 node Ready và một Spot node
  `ip-10-0-37-80` đang terminate/NotReady sau Karpenter disruption; không có node
  bị cordon thủ công. Đây chưa phải entry gate sạch.
- CoreDNS 2/2 Ready trên hai node và hai AZ.
- Grafana đã trở lại 1/1 Ready sau khi datasource provisioning được sắp lại.
- C2 vẫn live:
  `networkPolicy.enabled=true`, `networkPolicy.enforceEgress=true`,
  `egressProxy.enabled=true`; NetworkPolicy per-workload đang tồn tại.
- Egress proxy 2/2 Ready trên hai node/hai AZ.
- Snapshot lúc `16:44 +07`: Locust vẫn `running`, `200 users`, `10 workers`,
  khoảng `40.8 RPS`, `fail_ratio≈0.0030`. HPA còn giữ frontend `7`,
  frontend-proxy `4`, recommendation `6` và product-reviews `2`; một Spot node
  đang terminate nên `linkerd-cni` còn `Progressing`. Đây là tải ngoài evidence
  lane: không chạy baseline/AZ fault và không tự dừng run của team khác.
- Hai inventory Job lúc `16:35` và `16:40 +07` đều `Complete`; cluster-wide
  không có Job failed. Entry gate chỉ mở lại khi Locust `stopped`/`0 users`,
  mọi Deployment Available, tất cả node hiện hữu Ready/không cordon, không còn
  Spot/Karpenter churn và toàn bộ Argo application `Synced/Healthy`.
- PR #257 và #258 ngoài phạm vi Mandate 17 đã merge lần lượt lúc 14:25 và
  14:40, tăng currency `minReplicas`/CPU burst và tài nguyên OTel agent.
  PR #259 đã merge ở `ff7cb59`, bổ sung đúng Linkerd bypass TCP 6379 cho init
  probe của cart. Cart đã rollout `2/2`; cả hai Pod mới Ready với annotation
  `6379,10000,9901`. PR #260 harden AZ harness và đã merge ở `d216073`;
  revision live để retest từ đây là `d216073`. Không dùng
  baseline của revision cũ làm entry gate cho lần AZ-loss kế tiếp.

Không dùng snapshot capacity, Locust state hoặc SLO của audit trước làm evidence.
Sau khi inventory remediation pass, phải lấy lại baseline sạch năm phút và
capacity/placement mới ngay trước mỗi fault.

## 3. Phần đã hoàn thành — không làm lại

- Optional dependency timeout/fallback/degraded header và automated tests.
- ServiceAccount riêng, token-off, RBAC/IRSA inventory.
- PDB/topology spread và CoreDNS placement hai AZ.
- C1 ingress-only và C2 full egress containment.
- PolicyEndpoint/proxy, private ops, observability, flagd và storefront
  remediation.
- Positive Gate 4 và attacker matrix: DNS pass; lateral movement, Kubernetes
  API/token, data plane, proxy và Internet đều bị chặn; cleanup pass.
- Static NetworkPolicy/runtime-hardening test suite.
- LLM digest recovery.
- Checkout round-robin remediation đã được build, promote và Argo sync.

Không tạo lại C1/C2 PR, không promote image mới, không thêm dashboard/load
generator, không mở egress/CIDR và không sửa infra trước khi một live gate mới
chứng minh còn lỗi.

## 4. Bốn bước còn lại

### R0 — Tạo evidence lane do CDO tự sở hữu

R0 đã **PASS** cho baseline/dependency window; trước AZ-loss phải lấy một
baseline mới vì PR #259 đã đổi chart revision:

1. [x] Linkerd CNI/heartbeat/exception remediation đã merge; static test pass và
   inventory có hai lần `Complete` với `violationCount=0`.
2. [x] Merge remediation hẹp cho Linkerd CNI node-join race
   (`repairController` + `system-node-critical`) và chứng minh Pod bị validator
   fail được repair/recreate và workloads recover (PR #253); exception inventory
   hẹp cho `repair-controller/NON_ROOT` đã merge ở PR #255.
3. [x] Merge một PR hardening chỉ cho hai chaos script và test/runbook của chúng;
   không đổi application image, NetworkPolicy hoặc hạ tầng.
   PR #254 đã chuyển dependency fault sang deletion loop giữ nguyên desired
   replicas, chuyển AZ target sang runtime Deployment inventory, thêm `-Execute`
   guard/`-WhatIf` và static contract test. PR #256 loại rõ `flagd`,
   load-generator và observability khỏi AZ targets; CI/static test pass.
4. [x] HPA đã scale-down; Argo `techx-corp` Healthy và không có node/CNI churn
   trong official baseline 5 phút.

Hai baseline ngày 24/07 chưa phải evidence pass và không mở fault gate:

- `reliability-20260724-141759`: runner local có request timeout/đường truyền
  không ổn định; không inject fault.
- `reliability-20260724-142744`: runner local mất route tới nhiều IP CloudFront
  (`unreachable network`), đồng thời PR #257 rollout và Locust được bật lại;
  không inject fault.

Không hạ threshold và không dùng hai run này làm bằng chứng ứng dụng fail.
Official baseline `reliability-20260724-150008` đã pass trên revision
`45fcd05` bằng Docker k6 runner ngoài EKS: 601 iterations; browse `99.83%`,
cart `100%`, checkout `100%`, browse p95 `457.92 ms`, dropped iterations `0`,
k6 exit `0`. Sau run, 9/9 Argo `Synced/Healthy`, mọi Deployment Available,
7 node cũ Ready/uncordoned và Locust `stopped`/`0 users`.

Sau đó CDO dùng k6 riêng để có timestamps, thresholds và output độc lập:

- public storefront;
- `constant-arrival-rate`;
- 2 money-flow iterations/giây, xấp xỉ 8 HTTP request/giây;
- `PRE_ALLOCATED_VUS=40`, `MAX_VUS=40`;
- browse ≥99.5%, cart ≥99.5%, checkout ≥99%;
- browse p95 <1 giây; dropped iterations = 0.

Phụ thuộc liên-team duy nhất là một protected change window tối đa 45 phút:
owner dừng Locust về `stopped`/`0 users`; không rollout, promotion, performance
test hoặc chaos khác. Nếu state/user/worker hoặc revision thay đổi trong cửa sổ
thì hủy window và không quy lỗi cho Mandate 17.

Trước GO, CDO chạy read-only preflight:

1. Argo 9/9 `Synced/Healthy`, mọi Deployment Available.
2. Node Ready/không cordon; không termination/drain/scheduling storm.
3. CoreDNS 2/2 trên hai node/hai AZ; inventory Job mới Complete.
4. Chụp requests/allocatable mới cho AZ sống sót.
5. k6 baseline sạch 5 phút trên đúng revision/digest sẽ test.

Chỉ cần fault owner và rollback owner của CDO; không chuyển ownership fault cho
team AI.

### R1 — Hoàn thiện dependency fault evidence

**PASS ngày 24/07/2026** trong
`reliability-20260724-150008/dependency-ad`:

- `ad` giữ desired replicas `2`; EndpointSlice xuống `0` ready trong fault;
- 6/6 probe samples trả HTTP `200`, body `[]`, header
  `X-TechX-Degraded-Dependencies: ad`;
- frontend log có structured event `optional_dependency_fallback`;
- k6 600/600 browse/cart/checkout `100%`, browse p95 `525.46 ms`,
  dropped iterations `0`, exit `0`;
- `ad` restore `2/2`, hai endpoint Ready; 9/9 Argo Healthy, mọi node
  uncordoned và Locust vẫn stopped.

Dùng `ad`, hold 60 giây dưới k6 load. Không scale Deployment và không tắt/patch
Argo self-heal: `techx-corp` được root app quản lý nên thay đổi sync policy live
sẽ tạo thêm một tầng drift.

Chỉnh tối thiểu `mandate17-dependency-chaos.ps1` thành crash-loop fault:

1. giữ desired replicas ở 2;
2. trong 60 giây, xóa mọi `ad` pod mới được Deployment tạo lại;
3. chỉ mở acceptance window sau khi EndpointSlice xác nhận 0 ready endpoint;
4. dùng cache-busting probe và lưu timestamp, status, degraded header, body;
5. lưu log hoặc trace fallback;
6. trong `finally`, dừng deletion loop, đợi `ad` 2/2 Ready, Argo Healthy và
   recovery SLO.

Cách này mô phỏng dependency crash bất ngờ, không đấu với GitOps, không phụ
thuộc team khác và không cần platform/image PR. Script phải giữ `-WhatIf` thật
sự non-mutating và có explicit `-Execute` guard cho production.

Evidence bắt buộc trong cùng authoritative fault window:

- dependency thực sự unavailable;
- `/api/data` trả HTTP 200;
- body fallback là `[]`;
- `X-TechX-Degraded-Dependencies: ad`;
- structured log hoặc trace fallback;
- browse/cart/checkout đạt SLO, không dropped iteration;
- `ad` restore 2/2, Argo Healthy và recovery SLO sạch.

Nếu fail, dừng tại đây và chỉ sửa nguyên nhân đã chứng minh. Không chạy AZ fault
trên một recovery chưa sạch.

### R2 — Retest AZ-loss trên checkout image/digest hiện tại

Lần chạy đầu ngày 24/07 **không được tính là PASS** dù money path giữ SLO:

- k6 10 phút có 1.200/1.200 browse/cart/checkout `100%`, browse p95
  `677.23 ms`, dropped iterations `0`;
- hai node ban đầu đã được uncordon trong `finally`;
- Karpenter tạo node mới trong chính `us-east-1a` khi fault đang mở, nên fault
  chưa duy trì được ranh giới AZ;
- cart recovery kẹt ở init `wait-for-managed-valkey`, làm recovery gate timeout.

Root cause cart đã được chứng minh: Linkerd CNI redirect TCP 6379 của init
container trước khi proxy sidecar chạy. DNS, SG, NetworkPolicy và PolicyEndpoint
đều đúng; Pod annotation chỉ skip `10000,9901`. PR #259 thêm đúng override prod
`6379,10000,9901` và render assertion, không mở CIDR/rule mới. PR đã merge ở
`ff7cb59`; Argo hiện `Synced/Healthy` tại `d216073`, cart `2/2`, mọi Deployment Available và
inventory `violationCount=0`. Chỉ retest sau khi baseline mới pass.

Gap fault harness còn lại: phải ngăn Karpenter tạo node mới trong fault AZ
trong suốt acceptance window. Không được tự ý patch NodePool production;
phương án zone fence phải được duyệt rõ, snapshot/restore trong `finally` và
có static proof trước khi chạy.

Hardened harness đã merge qua PR #260 tại `d216073`: fence cả `stateless-spot` và
`stateless-on-demand`, dùng JSON Patch có `resourceVersion`/exact requirement
test, xác minh không có node mới trong AZ fault và restore exact zone values
trong `finally`. `-WhatIf`, server-side dry-run cho cả hai patch và toàn bộ
local/static suite đã pass. Chưa mutation production khi Locust còn chạy và
chưa có phê duyệt rõ cho `-FenceProvisioning`.

Không phân tích hoặc tạo remediation mới trước retest. Chụp exact checkout
image digest trước baseline; đó là candidate duy nhất cho retest hiện tại.

1. Lấy capacity snapshot mới. Với placement hiện tại, ưu tiên fault
   `us-east-1a` (hiện có hai node) và xác minh năm node `us-east-1b` đủ requests
   headroom. Xác minh lại Locust master/workers vẫn nằm ở AZ sống sót.
2. Harden `mandate17-az-chaos.ps1` trong cùng PR script: thay fixed list dễ bỏ
   sót bằng inventory first-party Deployment pods; loại trừ rõ load-generator
   và cluster-managed/observability/Job/StatefulSet resources; loại trừ `flagd`
   đúng ràng buộc mentor; in danh sách target để review trước `-Execute`.
3. Cordon toàn bộ node `us-east-1a`, xóa đồng thời first-party Deployment pods
   đang nằm trong AZ đó và giữ fault 300 giây dưới cùng k6 profile. Sau delete,
   xác nhận không còn target pod Ready trên node fault; nếu còn thì fail gate.
4. Thu exact checkout status/body/log/trace theo timestamp; không chỉ lưu số
   tổng.
5. Pass khi browse/cart/checkout đạt SLO, DNS/flagd hoạt động và dropped
   iterations = 0.
6. `finally` phải uncordon mọi node còn tồn tại; node đã bị Karpenter thay phải
   được ghi là `NotFound/replaced`, rồi xác minh toàn bộ node hiện hữu không
   cordon.
7. Chờ mọi workload Available, Argo Healthy và lấy recovery SLO.

Nếu retest pass, không cần thêm checkout/infra change. Nếu vẫn fail, dừng,
đối chiếu exact failure với capacity, PDB/topology, endpoint churn và Karpenter;
chỉ lúc đó mới mở một remediation PR hẹp rồi lặp R0–R2.

### R3 — Gate 5 evidence và evidence PR

Cập nhật `tf2-corp-chart/docs/evidence/mandate-17/README.md` và
`resilience.md` với:

- exact platform/chart/infra SHA, Argo revision và image digest;
- k6 baseline/dependency/AZ/recovery timestamps và raw summaries;
- fallback status/body/header/log hoặc trace;
- CoreDNS/node/AZ/capacity và cleanup snapshots;
- bằng chứng C2/PolicyEndpoint/proxy/RBAC/IRSA/attacker đã có;
- rollback proof thực tế: `ad` restore và AZ uncordon/recovery;
- lệnh one-command để mentor chạy lại dependency hoặc AZ fault và attacker.

Không cần live rollback C2 chỉ để làm evidence; giữ documented C2 rollback
`true/true → true/false → false/false` và static rendered proof. Chỉ tạo một
evidence PR sau khi R1 và R2 đều pass. Không commit secret, token,
authorization header, webhook URL hoặc raw customer data.

## 5. Definition of Done

- [x] Dependency fault có đầy đủ body/header/log-or-trace và money path giữ SLO.
- [ ] AZ-loss retest giữ DNS và browse/cart/checkout SLO; cleanup/recovery pass.
- [x] C2 NetworkPolicy/egress containment đang live và attacker matrix pass.
- [x] Least-privilege ServiceAccount/RBAC/token/IRSA pass.
- [x] Flagd, public/private exposure và observability evidence đã pass; entry
  gate vẫn cần inventory Job mới Complete.
- [ ] Evidence index, cleanup/rollback proof và mentor repro được review/merge.

Mandate 17 hoàn thành khi hai checkbox còn trống đều được đóng. Happy path không
cần thêm application, image, chart activation hoặc infra PR; chỉ cần một PR
hardening hai script, hai live fault chạy tuần tự trong cùng protected window
và một evidence PR.

## 6. Quyết định sau audit hiện tại

- **DONE** Linkerd exception/CNI remediation, inventory pass và chaos script
  hardening (PR #253–#256).
- **DONE** read-only preflight/baseline tại `45fcd05` và R1 dependency fault.
- **DONE** cart init/Linkerd remediation PR #259 và AZ harness PR #260; live
  revision `d216073`, cart `2/2`, inventory pass và không còn Job failed.
- **HOLD** trước R2: lúc `16:44 +07`, Locust còn chạy 200 users, HPA chưa
  scale-down, một Spot node đang terminate và `linkerd-cni` còn `Progressing`.
  Chờ entry gate sạch, lấy baseline mới trên `d216073`, snapshot capacity mới và
  phê duyệt rõ `-FenceProvisioning`. Không tự ý dừng test của team khác hoặc
  patch NodePool production.
- Nếu R1 và R2 pass: đi thẳng R3, không điều tra/mở remediation khác.
- Nếu gate nào fail: dừng tại gate đó; không hạ SLO, không mở network và không
  gộp thêm thay đổi chưa có bằng chứng.
