# Exchange Platform Monorepo

Production-oriented spot exchange monorepo with locked stack and gate-driven delivery.

## Locked stack
- Trading Core: Rust
- Edge Gateway: Go (REST + WS)
- Ledger/Settlement: Kotlin + Spring Boot + PostgreSQL
- Contracts/Event Log: Protobuf + Redpanda(Kafka API)
- Streaming: Flink
- Cache/History/Archive: Redis / ClickHouse / MinIO(S3)
- Infra/Ops: Docker Compose(local), Kubernetes + OTel + GitOps(target)

## Repo layout
```text
contracts/
  proto/                  # source-of-truth protobuf schemas
  gen/                    # generated stubs (go/rust/kotlin)
services/
  trading-core/           # Rust
  edge-gateway/           # Go
  ledger-service/         # Kotlin
streaming/
  flink-jobs/             # Java/Flink skeleton
infra/
  compose/                # local infra stack
  k8s/                    # k8s placeholders
  gitops/                 # gitops placeholders
scripts/
  smoke_g0.sh             # gate G0 local smoke
  smoke_g3.sh             # gate G3 ledger safety smoke
  smoke_reconciliation_safety.sh # reconciliation lag/safety auto-mode smoke
  exactly_once_stress.sh  # duplicate trade injection (exactly-once effect proof)
  chaos/                  # standardized crash drills (core/ledger/redpanda/full)
  smoke_e2e.sh            # minimal E2E: Edge -> Core -> Kafka -> Ledger
  smoke_match.sh          # Gate G1 real match smoke (BUY+SELL crossing)
  load_smoke.sh           # I-0105 load smoke harness
  dr_rehearsal.sh         # I-0106 backup/restore rehearsal
  safety_case.sh          # I-0108 evidence bundle generator
web-user/
  src/                    # web-user frontend (Vite + React)
```

## Local Quickstart (E2E happy path)
1) Bring up infra dependencies:
```bash
docker compose -f infra/compose/docker-compose.yml up -d
```

2) Run the minimal E2E smoke (starts core/edge/ledger locally):
```bash
./scripts/smoke_e2e.sh
```

## Dev environment doctor (fresh macOS)
Run this first on a new machine:
```bash
make doctor
```

If doctor fails, install missing tools with Homebrew (example):
```bash
brew install protobuf go openjdk@21
```

For Rust, install via rustup:
```bash
curl https://sh.rustup.rs -sSf | sh
```

## Web user frontend (alpha)
```bash
cd web-user
npm install
npm run dev
```

- default dev URL: `http://localhost:5173`
- default proxy target: `http://localhost:8081` (override: `VITE_PROXY_TARGET`)

## Gate G0 commands
### 1) Contracts
If `buf` is installed locally:
```bash
buf lint
buf generate
```
If not, run with Docker:
```bash
docker run --rm -v "$PWD":/workspace -w /workspace bufbuild/buf:1.37.0 lint
docker run --rm -v "$PWD":/workspace -w /workspace bufbuild/buf:1.37.0 generate
```

### 2) Tests
```bash
cargo test
go test ./...
./gradlew test
```


Rust protobuf build note (Trading Core):
- `cargo test -p trading-core` requires `protoc` + Google well-known includes (`google/protobuf/*.proto`).
- On macOS this is normally provided by `brew install protobuf` (`/opt/homebrew/include` or `/usr/local/include`).
- If installed in a custom location, set `PROTOC_INCLUDE=/path/to/include`.

### 2.1) Ops/Infra validation
```bash
./scripts/validate_infra.sh
./scripts/load_smoke.sh
./scripts/dr_rehearsal.sh
./scripts/invariants.sh
make safety-case
```

### 3) Infra up
```bash
docker compose -f infra/compose/docker-compose.yml up -d
```

### 4) Smoke (minimum path)
```bash
./scripts/smoke_g0.sh
```
This script verifies:
- order creation with `Idempotency-Key`
- synthetic trade settlement row appended to Postgres
- WebSocket `TradeExecuted` and `CandleUpdated` fan-out observed

### 5) Smoke (ledger safety path)
```bash
./scripts/smoke_g3.sh
```

### 6) Smoke (E2E wiring)
```bash
./scripts/smoke_e2e.sh
```
This script verifies:
- order creation on edge with accepted response
- `TradeExecuted` publish to `core.trade-events.v1`
- ledger append lookup for the trade via REST

### 7) Smoke (reconciliation safety auto-trigger)
```bash
./scripts/smoke_reconciliation_safety.sh
```
This script verifies:
- core trade seq keeps moving while settlement consumer is paused
- reconciliation lag grows above threshold
- ledger auto-triggers `CANCEL_ONLY` safety mode on trading core
- new orders are rejected with `CANCEL_ONLY`
- after lag recovery, safety latch is manually released via admin API
- trading returns to non-`CANCEL_ONLY` mode

### 8) E2E Smoke (no frontend, real matching path)
Exact command sequence on a fresh machine:
```bash
make doctor
docker compose -f infra/compose/docker-compose.yml up -d
./scripts/smoke_match.sh
```

### 9) Exactly-once stress (duplicate injection)
```bash
# default: 10,000 duplicate submissions, configurable up to 1,000,000+
REPEATS=1000000 CONCURRENCY=64 ./scripts/exactly_once_stress.sh
```
This script verifies:
- same `tradeId` is injected repeatedly
- ledger applies exactly once (`applied=true` only once)
- all other submissions are blocked as duplicates
- balances reflect a single settlement effect

### 10) Chaos drills (standardized)
```bash
make chaos-full      # core+ledger kill/restart replay drill
make chaos-core      # core-only kill/restart drill
make chaos-ledger    # ledger-only kill/restart drill
make chaos-redpanda  # broker bounce drill
```
`chaos-full` success output includes:
- `chaos_replay_success=true`
- `core_recovery_hash` continuity proof
- `ledger_duplicate_rows=0`
- `invariants_ok=true`  
  - in stub-trade mode, `invariants_warning=negative_balances_present_under_stub_mode` can appear

`smoke_match.sh` verifies these checkpoints:
- (a) trading-core gRPC port is listening
- (b) Edge `POST /v1/orders` reaches Core `PlaceOrder`
- (c) `TradeExecuted` exists on topic `core.trade-events.v1` (via `docker compose exec redpanda rpk ...`)
- (d) ledger reflects `tradeId` through REST (`GET /v1/admin/trades/{tradeId}`)

## Gate G1 status
- Trading Core implements:
  - command contract handling (`PlaceOrder`, `CancelOrder`, `SetSymbolMode`, `CancelAll`)
  - price-time priority orderbook (FIFO in level, best-price across levels)
  - LIMIT/MARKET matching with deterministic sequencing
  - risk hot-path guards (reserve, rate/open-order limits, price band)
  - WAL (CRC framed records) with durable-before-outbox commit line
  - snapshot + WAL-tail recovery
  - determinism state hashing and replay checks
  - fencing token checks for split-brain defense
  - durable outbox with retry-safe publish cursor
- Edge Gateway implements:
  - `/v1/orders` routed to Trading Core gRPC `PlaceOrder` (no local accepted fallback)
  - Kafka `TradeExecuted` consume path for WS market stream updates
  - local order status cache updated from core responses + trade events (`ACCEPTED/PARTIALLY_FILLED/FILLED`)

Market order liquidity policy (v1):
- partial fills are allowed
- unfilled remainder is canceled (non-resting)

## Gate G3 status
- Ledger service implements:
  - append-only double-entry schema + Flyway migration
  - idempotent settlement consumer path (`trade_id` dedup via unique trade reference)
  - reserve model (`available`↔`hold`) for reserve/release/fill
  - balances materialization and rebuild endpoint
  - invariant checks + reconciliation gap tracking
  - periodic reconciliation evaluation + history + auto safety-mode trigger
  - correction workflow (request, 2-person approval, reversal apply)
  - Kafka consumer baseline (`LEDGER_KAFKA_ENABLED=true`)

## Gate G2/3 parallel status (B-0401~B-0403 baseline)
- Streaming module includes deterministic:
  - 1m candle aggregation with boundary finalization and seq-preferred out-of-order handling
  - rolling 24h ticker aggregation
- ClickHouse init schema added for:
  - `exchange.trades` (partition by day, order by symbol+time+seq)
  - `exchange.candles` (partition by day, order by symbol+interval+open_time)

## Gate G4 proximity status (I-0101~I-0108 baseline)
- Kubernetes baseline manifests:
  - namespaces (`core`, `edge`, `ledger`, `streaming`, `infra`)
  - deny-by-default network policies with explicit allow rules
  - RBAC and JIT access templates
- GitOps baseline:
  - ArgoCD `AppProject`, root app-of-apps, `dev/staging/prod` applications
- Observability baseline:
  - OTel collector spanmetrics pipeline and Prometheus scraping
  - edge request tracing + `X-Trace-Id` response header
- Security/ops baseline:
  - secrets policy + KMS/HSM plan
  - secret rotation drill and JIT access helper scripts
- Release evidence baseline:
  - load smoke report
  - DR rehearsal report
  - `make safety-case` artifact bundle + integrity hash

## Service endpoints (local)
- Edge Gateway: `http://localhost:8081`
  - `GET /healthz`
  - `GET /readyz`
  - `GET /metrics`
  - `POST /v1/auth/signup`
  - `POST /v1/auth/login`
  - `GET /v1/auth/me`
  - `POST /v1/auth/logout`
  - `GET /v1/account/balances`
  - `GET /v1/account/portfolio`
  - `POST /v1/orders`
  - `DELETE /v1/orders/{orderId}`
  - `GET /v1/orders/{orderId}`
  - `POST /v1/smoke/trades` (test-only; requires `EDGE_ENABLE_SMOKE_ROUTES=true`)
  - `GET /v1/markets/{symbol}/trades`
  - `GET /v1/markets/{symbol}/orderbook`
  - `GET /v1/markets/{symbol}/candles`
  - `GET /v1/markets/{symbol}/ticker`
  - `GET /ws`
- Ledger Service: `http://localhost:8082`
  - `GET /healthz`
  - `GET /readyz`
  - `GET /metrics`
  - `POST /v1/internal/trades/executed`
  - `POST /v1/internal/orders/reserve`
  - `POST /v1/internal/orders/release`
  - `POST /v1/internal/reconciliation/engine-seq`
  - `POST /v1/admin/adjustments`
  - `GET /v1/admin/balances` (optional `X-Admin-Token` when `LEDGER_ADMIN_TOKEN` set)
  - `GET /v1/balances` (legacy alias, deprecated)
  - `POST /v1/admin/rebuild-balances`
  - `POST /v1/admin/invariants/check`
  - `GET /v1/admin/reconciliation/{symbol}`
  - `GET /v1/admin/reconciliation/status`
  - `POST /v1/admin/reconciliation/latch/{symbol}/release`
  - `POST /v1/admin/consumers/settlement/pause`
  - `POST /v1/admin/consumers/settlement/resume`
  - `GET /v1/admin/consumers/settlement/status`
  - `POST /v1/admin/corrections/requests`
  - `POST /v1/admin/corrections/{correctionId}/approve`
  - `POST /v1/admin/corrections/{correctionId}/apply`
- Postgres: `localhost:25432`
- Redpanda Kafka: `localhost:29092`
- Redpanda HTTP proxy: `localhost:28082`
- Redis: `localhost:26380`
- ClickHouse HTTP/TCP: `localhost:28123` / `localhost:29000`
- MinIO API/Console: `localhost:29002` / `localhost:29001`
- OTel collector OTLP gRPC/HTTP: `localhost:24317` / `localhost:24318`
- Prometheus: `localhost:29090`

## Non-negotiable constraints
- Trading Core hot-path must not make synchronous DB calls.
- "Executed" commit-line is after WAL durable write only.
- Ledger is append-only; corrections only via reversal/adjustment.
- Every event must include `event_id`, `event_version`, `symbol`, `seq`, `occurred_at`, `correlation_id`, `causation_id`.
- WS must enforce backpressure and allow conflation for book/candle streams.

## Edge auth (G2)
Configure auth in env:
- `EDGE_API_SECRETS="key1:secret1,key2:secret2"`
- `EDGE_AUTH_SKEW_SEC=30`
- `EDGE_REPLAY_TTL_SEC=120`
- `EDGE_RATE_LIMIT_PER_MINUTE=1000`
- `EDGE_DISABLE_CORE=true` (optional: 코어 없이 마켓 조회/WS만 실행)
- `EDGE_SEED_MARKET_DATA=true` (default: server boot 시 샘플 마켓 데이터 자동 주입)
- `EDGE_ENABLE_SMOKE_ROUTES=false` (default; test scripts only set `true`)
- `EDGE_SESSION_TTL_HOURS=24`
- `EDGE_KAFKA_BROKERS=localhost:29092` (core trade event consume)
- `EDGE_KAFKA_TRADE_TOPIC=core.trade-events.v1`
- `EDGE_KAFKA_GROUP_ID=edge-trades-v1`
- `EDGE_WS_MAX_SUBSCRIPTIONS=64` (per connection)
- `EDGE_WS_COMMAND_RATE_LIMIT=240` (commands per window)
- `EDGE_WS_COMMAND_WINDOW_SEC=60`
- `EDGE_WS_PING_INTERVAL_SEC=20`
- `EDGE_WS_PONG_TIMEOUT_SEC=60`
- `EDGE_WS_READ_LIMIT_BYTES=1048576`
- `EDGE_WS_ALLOWED_ORIGINS=https://app.exchange.example,https://admin.exchange.example` (optional allowlist)

`EDGE_DISABLE_CORE=true`에서는 주문 API가 `core_unavailable`로 거절됩니다.
주문/체결 플로우 테스트는 Trading Core 실행이 필요합니다.

Request headers for trading endpoints:
- `X-API-KEY`
- `X-TS` (epoch ms)
- `X-SIGNATURE` (HMAC-SHA256 of `METHOD\nPATH\nX-TS\nBODY`)
- `Idempotency-Key` (POST/DELETE required)

## OTel config (I-0102)
Edge env:
- `EDGE_OTEL_ENDPOINT=localhost:24317`
- `EDGE_OTEL_INSECURE=true`
- `EDGE_OTEL_SERVICE_NAME=edge-gateway`
- `EDGE_OTEL_SAMPLE_RATIO=1.0`

Ledger env:
- `LEDGER_OTEL_ENDPOINT=http://localhost:24318/v1/traces`
- `LEDGER_OTEL_SAMPLE_PROB=1.0`
- `LEDGER_RECONCILIATION_ENABLED=true`
- `LEDGER_RECONCILIATION_INTERVAL_MS=5000`
- `LEDGER_RECONCILIATION_LAG_THRESHOLD=10`
- `LEDGER_RECONCILIATION_STATE_STALE_MS=30000` (latest seq update freshness budget)
- `LEDGER_ADMIN_TOKEN=` (optional; when set, `/v1/admin/**` and `/v1/balances` require `X-Admin-Token`)
- `LEDGER_RECONCILIATION_SAFETY_MODE=CANCEL_ONLY` (`SOFT_HALT`/`HARD_HALT` supported)
- `LEDGER_RECONCILIATION_AUTO_SWITCH=true`
- `LEDGER_RECONCILIATION_SAFETY_LATCH_ENABLED=true` (breach latched until manual release)
- `LEDGER_RECONCILIATION_LATCH_ALLOW_NEGATIVE=false` (stub smoke only: `true` 허용 가능)
- `LEDGER_GUARD_AUTO_SWITCH=true` (`false` to keep invariant scheduler as monitor-only)
- `LEDGER_GUARD_SAFETY_MODE=CANCEL_ONLY`

Safety latch release contract:
- `POST /v1/admin/reconciliation/latch/{symbol}/release`
- release is allowed only when:
  - reconciliation is recovered (`lag==0`, no mismatch/threshold breach)
  - invariant check passes at release time

Reconciliation alert rule examples:
- `infra/observability/reconciliation-alert-rules.example.yml`

Reconciliation metrics (ledger `/metrics`):
- `reconciliation_lag_max`
- `reconciliation_breach_active`
- `reconciliation_alert_total`
- `reconciliation_mismatch_total`
- `reconciliation_stale_total`
- `reconciliation_safety_trigger_total`
- `reconciliation_safety_failure_total`
- `invariant_safety_trigger_total`
- `invariant_safety_failure_total`
