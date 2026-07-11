# Probe thresholds and handler policy

This document is the **source of truth** for Kubernetes health probes on first-party workloads in `techx-corp-chart`. Configuration lives in `values.yaml` under each `components.*` block and is rendered by `templates/_objects.tpl`.

OpenSearch cold-start history is also covered in:

* `docs/changes/2026-07-10-opensearch-startup-probe-memory-lock.md`
* `docs/changes/2026-07-10-opensearch-cpu-startup-margin.md`

---

## 1. Goals

* Gate Service traffic with **readiness** until the process can accept work.
* Restart hung processes with **liveness** without thrashing healthy pods.
* Prefer **native health** (`grpc`, lightweight `httpGet`) over `tcpSocket` when the app exposes it.
* Set **explicit** timings so we do not inherit Kubernetes `timeoutSeconds: 1`.
* Keep **demo chaos** safe: cart `failedReadinessProbe` must not force restarts.
* Document **why** each number exists so operators tune the right field after incidents.

---

## 2. Kubernetes probe math

| Field | Kube default | Meaning |
|---|---|---|
| `periodSeconds` | 10 | How often kubelet probes |
| `timeoutSeconds` | **1** | Max time for a single probe attempt |
| `failureThreshold` | 3 | Consecutive failures before action |
| `successThreshold` | 1 | Consecutive successes to become Ready / pass |
| `initialDelaySeconds` | 0 | Delay before first probe |
| `startupProbe` | unset | While failing, blocks liveness; used for long boots |

**Approximate windows (after delays / after startup succeeds):**

```text
unready_or_restart_after ≈ periodSeconds × failureThreshold
```

Chart global rollout default `progressDeadlineSeconds: 300` (5 minutes). Tier A–C readiness budgets stay well under that. OpenSearch uses a longer **startupProbe** and is the documented exception.

---

## 3. Design principles

1. **Readiness removes endpoints; liveness restarts the container.** Do not couple liveness to temporary dependency or chaos signals that only belong on readiness.
2. **cart + `failedReadinessProbe`:** the gRPC health check honors an OpenFeature flag meant to fail **readiness** for demos. Liveness uses **`tcpSocket`** so enabling the flag drains traffic without CrashLoop.
3. **Handler preference:** `grpc` health when registered → lightweight HTTP health (`/ready`, `/status`) → `tcpSocket` when no health route exists.
4. **Explicit timings** on every probe block (no reliance on `timeoutSeconds: 1`).
5. **startupProbe** where cold start repeatedly races liveness (OpenSearch, Kafka). Prefer initContainers for hard deps of *other* services (already used for kafka/postgres/valkey waits).
6. **Workers without stable listeners** (`accounting`, `fraud-detection`) are intentionally unprobed until app-level consumer health exists (REL-02 follow-ups).

---

## 4. Tier model

| Tier | Profile | readiness (typical) | liveness (typical) | Components |
|---|---|---|---|---|
| **A – Fast** | Envoy/nginx/native/cache; quick bind | period 10, timeout 2, fail 3 (~30s) | period 20, timeout 3, fail 3 (~60s) | frontend-proxy, image-provider, flagd, currency, shipping, valkey-cart |
| **B – Standard app** | Managed runtimes; modest CPU | period 10, timeout 3, fail 3 (~30s) | period 15, timeout 5, fail 5 (~75s) | cart*, checkout, payment, product-catalog, product-reviews, recommendation, quote, email, llm, frontend† |
| **C – JVM / Guaranteed DS** | JVM or tight Guaranteed CPU cold start | larger fail budget, timeout 5 | slower period, timeout 5 | ad, kafka, postgresql |
| **D – Multi-minute** | Documented long bootstrap | existing OpenSearch set | existing | opensearch |

\* cart: readiness gRPC (Tier B timings); liveness **tcpSocket** (Tier B liveness timings).  
† frontend: Tier B structure but **timeoutSeconds: 5** and liveness period 20 / fail 4 (~80s) because `GET /` is a full page.

---

## 5. Per-component matrix

| Component | readiness | liveness | period R/L | timeout R/L | fail R/L | Window R / L |
|---|---|---|---|---|---|---|
| ad | grpc :8080 | grpc :8080 | 10 / 20 | 5 / 5 | 6 / 5 | 60s / 100s |
| cart | grpc :8080 | **tcp :8080** | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| checkout | grpc :8080 | grpc :8080 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| currency | grpc :8080 | grpc :8080 | 10 / 20 | 2 / 3 | 3 / 3 | 30s / 60s |
| email | tcp :8080 | tcp :8080 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| frontend | http `GET /` :8080 | same | 10 / 20 | 5 / 5 | 3 / 4 | 30s / 80s |
| frontend-proxy | http `GET /ready` **:10000** | same | 10 / 20 | 2 / 3 | 3 / 3 | 30s / 60s |
| image-provider | http `GET /status` :8081 | same | 10 / 20 | 2 / 3 | 3 / 3 | 30s / 60s |
| payment | grpc :8080 | grpc :8080 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| product-catalog | grpc :8080 | grpc :8080 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| product-reviews | grpc :3551 | grpc :3551 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| quote | tcp :8080 | tcp :8080 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| recommendation | grpc :8080 | grpc :8080 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| shipping | tcp :8080 | tcp :8080 | 10 / 20 | 2 / 3 | 3 / 3 | 30s / 60s |
| flagd | tcp :8013 | tcp :8013 | 10 / 20 | 2 / 3 | 3 / 3 | 30s / 60s |
| llm | tcp :8000 | tcp :8000 | 10 / 15 | 3 / 5 | 3 / 5 | 30s / 75s |
| kafka | tcp :9092 (+ **startup**) | tcp :9092 | 10 / 30 (+ startup 10) | 5 / 5 | 3 / 5 (+ startup fail 36) | startup ~6.2m; then R 30s / L 150s |
| postgresql | tcp :5432 | tcp :5432 | 10 / 20 | 5 / 5 | 6 / 5 | 60s / 100s |
| valkey-cart | tcp :6379 | tcp :6379 | 10 / 20 | 2 / 3 | 3 / 3 | 30s / 60s |
| opensearch | tcp :9200 (+ startup) | tcp :9200 | see §6 | 5 / 5 | see §6 | startup ~6.5m |

**Not probed:** `accounting`, `fraud-detection`, `load-generator`, `flagd-ui` sidecar.

---

## 6. Component-by-component rationale

### ad (Tier C – Java)

* **Runtime / resources:** JVM; requests 100m CPU / 128Mi, limits 300m / 300Mi.
* **Handler:** gRPC health set to SERVING after server start (`HealthStatusManager`).
* **Thresholds:** readiness fail 6 + timeout 5 (~60s) for JVM class load; liveness period 20 / fail 5 (~100s) so GC pauses do not thrash.
* **Rejected:** default timeout 1s; huge `initialDelaySeconds` without post-ready liveness.

### cart (Tier B – special liveness)

* **Runtime / resources:** .NET; 100m/128Mi request; initContainer waits for valkey.
* **Handler:** gRPC health runs OpenFeature `failedReadinessProbe` (demo chaos), not a Valkey connectivity check.
* **Thresholds:** standard Tier B readiness on gRPC; **liveness tcpSocket** with Tier B liveness timings.
* **Rejected:** identical gRPC liveness (chaos flag would restart pods).

### checkout (Tier B – Go)

* **Resources:** 50m/64Mi request; initContainer waits for kafka.
* **Handler:** gRPC health always SERVING once process is up.
* **Thresholds:** Tier B standard (~30s / ~75s).
* **Rejected:** tcpSocket (loses gRPC health protocol).

### currency (Tier A – C++)

* **Resources:** **20m** CPU request (throttle risk) but native binary.
* **Handler:** gRPC health always SERVING.
* **Thresholds:** Tier A with timeout 2 (not 1) for low-CPU spikes.
* **Rejected:** Tier C budgets (boot is not multi-minute).

### email (Tier B – Ruby / Sinatra)

* **Handler:** only business routes (e.g. `POST /send_order_confirmation`); no health path → **tcpSocket**.
* **Thresholds:** Tier B; TCP only proves listener up.
* **Rejected:** fake `httpGet /` (may 404 and fail wrongly).

### frontend (Tier B† – Next.js)

* **Handler:** `GET /` on :8080 (no dedicated `/health` today).
* **Thresholds:** timeout **5s**; liveness period 20 / fail 4 (~80s) for slower page paths.
* **Rejected:** probing internal API without a stable health route.

### frontend-proxy (Tier A – Envoy)

* **Handler:** Envoy admin **`GET /ready` on port 10000** (`ENVOY_ADMIN_PORT`), not data-plane `GET /` on 8080.
* **Why:** `/ready` reflects proxy readiness; `/` on 8080 depends on upstream frontend routing.
* **Thresholds:** Tier A (~30s / ~60s).
* **Rejected:** data-plane path (upstream coupling).

### image-provider (Tier A – nginx)

* **Handler:** `GET /status` (`stub_status` in nginx config) on :8081.
* **Thresholds:** Tier A.
* **Rejected:** tcp-only when `/status` already exists.

### payment (Tier B – Node)

* **Handler:** gRPC health SERVING.
* **Thresholds:** Tier B standard.
* **Rejected:** tcpSocket.

### product-catalog (Tier B – Go)

* **initContainer** waits for postgresql before main starts.
* **Handler:** gRPC health SERVING.
* **Thresholds:** Tier B (probe measures app, not DB boot).

### product-reviews (Tier B – Python)

* **Port:** **3551** (not 8080).
* **Handler:** gRPC health SERVING; initContainer waits for postgresql.
* **Thresholds:** Tier B.

### quote (Tier B – PHP)

* **Handler:** only `/getquote` business route → **tcpSocket** :8080.
* **Thresholds:** Tier B.

### recommendation (Tier B – Python)

* **Handler:** gRPC health registered; was missing from chart values (gap closed).
* **Thresholds:** Tier B; larger memory for cache feature flag does not change probe math.

### shipping (Tier A – Rust)

* **Resources:** 20m CPU; HTTP business routes only → **tcpSocket**.
* **Thresholds:** Tier A (fast native bind).

### flagd (Tier A – Go control plane)

* **Handler:** tcp :8013 (RPC port from command flags).
* **Thresholds:** Tier A.
* **Note:** `flagd-ui` sidecar has no probe (UI only; pod readiness follows main container).

### llm (Tier B – Flask)

* **Handler:** no health route → **tcpSocket** :8000.
* **Thresholds:** Tier B.
* **Note:** chart currently omits resource requests/limits for llm; tune separately if throttle appears.

### kafka (Tier C – JVM broker + startupProbe)

* **Resources:** Guaranteed **200m** CPU, **700Mi**, heap `-Xmx400M`; image also loads OTEL Java agent (`KAFKA_OPTS`).
* **Compose:** `nc -z` start_period 10s, interval 5s, retries 10 — optimistic vs K8s cold start under Guaranteed CPU.
* **Handler:** **tcpSocket** :9092 (plaintext listener).
* **Problem observed:** readiness + liveness both saw `connection refused` while KRaft/JVM was still binding; without `startupProbe`, liveness counted those failures and restarted mid-boot (same class of bug as early OpenSearch).
* **Thresholds:**
  * **startupProbe:** initialDelay 20s, period 10, timeout 5, failureThreshold **36** (~6.2 minutes: 20s + 36×10s) — gates liveness until :9092 accepts.
  * **readiness:** period 10, timeout 5, fail 3 (after startup succeeds).
  * **liveness:** period 30, timeout 5, fail 5 (only after first successful startup probe).
* **Rejected:** readiness-only longer failureThreshold without startup (liveness still kills); exec with kafka scripts (image/path fragility).

### postgresql (Tier C – Guaranteed)

* **Resources:** Guaranteed **100m** CPU / **128Mi**.
* **Compose:** `pg_isready` start_period 10s, timeout 5s, retries 5.
* **Handler:** **tcpSocket** :5432 (no client binary required in security-hardened image assumptions).
* **Thresholds:** readiness fail 6 (~60s), timeout 5; liveness ~100s.
* **Rejected:** exec `pg_isready` without guaranteeing client presence under current security context.

### valkey-cart (Tier A – cache)

* **Compose:** `valkey-cli ping` start_period 5s, retries 5.
* **Handler:** **tcpSocket** :6379.
* **Thresholds:** Tier A (fast process).
* **Rejected:** exec ping (extra binary/path coupling).

### opensearch (Tier D – unchanged)

* **Observed:** on 200m CPU, :9200 often bound only after ~4m+; chart uses 500m CPU + startupProbe.
* **startupProbe:** initialDelay 30, period 10, timeout 5, failureThreshold **36** (~6.5 minutes after start).
* **readiness:** period 10, timeout 5, fail 3 (after startup succeeds).
* **liveness:** period 30, timeout 5, fail 5.
* **Handler:** TCP :9200 (not HTTP cluster health) — sufficient to avoid mid-bootstrap kills; cluster color is a possible future upgrade.
* **Do not shorten** startup failureThreshold without cluster evidence.

---

## 7. Mapping from docker-compose healthchecks

| Compose service | Compose signal | Chart choice |
|---|---|---|
| kafka | `nc -z` + long retries | tcp :9092 + **startupProbe** (K8s cold start longer than compose) |
| postgresql | `pg_isready` | tcp :5432 + timeout 5 / fail 6 |
| valkey-cart | `PING` | tcp :6379 Tier A |
| opensearch | HTTP cluster health | TCP + long startup (chart history) |
| app services | mostly none | derived from gRPC/HTTP/tcp in matrix |

---

## 8. Observability: which Events mean what

| Event / symptom | Likely cause | First field to adjust |
|---|---|---|
| `Readiness probe failed` for first N seconds then Ready | Normal cold start | Raise readiness `failureThreshold` or add `startupProbe` if liveness kills |
| `Liveness probe failed` / container restart mid-boot | Liveness racing startup | Add/extend `startupProbe`; do not only raise liveness initialDelay forever |
| Continuous readiness failures after process up | Wrong path/port/handler or real unhealthy | Fix handler; check app logs |
| cart NotReady only when flag on | Expected chaos | Do not “fix” with liveness grpc |
| frontend-proxy NotReady, frontend OK | Admin :10000 /ready issue | Check Envoy admin bind and probe port |
| OpenSearch Unhealthy connection refused for minutes | Expected until :9200 binds | Do not panic; confirm startupProbe budget |
| Kafka Unhealthy connection refused then restarts | Liveness racing JVM/KRaft boot | Ensure `startupProbe` present; do not only raise liveness period |

---

## 9. Tuning runbook

1. Capture `kubectl describe pod` Events and container restart count.
2. Identify **readiness** vs **liveness** vs **startup**.
3. Prefer order of changes:
   1. Correct **handler/port/path** if wrong.
   2. Increase **timeoutSeconds** if probes time out under CPU throttle.
   3. Increase **failureThreshold** (or period) if boot is legitimately long.
   4. Add **startupProbe** only for multi-minute or liveness-kill-during-boot cases.
4. Keep readiness **stricter or equal** to liveness for “should receive traffic” vs “should be restarted.”
5. Update **this document and `values.yaml` together** so the matrix stays accurate.
6. Re-validate with `helm template` and a dev rollout; watch for CrashLoop and prolonged NotReady.

---

## 10. Out of scope / follow-ups

| Item | Status |
|---|---|
| `accounting` / `fraud-detection` consumer health | REL-02-FU-01 / FU-02 (app-level) |
| `load-generator` probe policy | Optional non-prod |
| OpenSearch HTTP `_cluster/health` | Future reliability improvement |
| Dedicated frontend `/api/health` | Platform change |
| llm resource requests/limits | Separate REL-06-style work |
| Subchart probes (Prometheus, Grafana, OTel, …) | Owned by upstream charts |

---

## Related docs

* `docs/operations/rollout-safety.md` — rollout strategy and deploy gates
* `docs/backlogs/2026-07-08-rel-02-health-probes.md` — original probe backlog
* `docs/backlogs/2026-07-08-rel-08-rollout-safety.md` — rollout + schema probe types
* `UPGRADING.md` — historical REL-02 notes (handler types)
