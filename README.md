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
  smoke_e2e.sh            # minimal E2E: Edge -> Core -> Kafka -> Ledger
  load_smoke.sh           # I-0105 load smoke harness
  dr_rehearsal.sh         # I-0106 backup/restore rehearsal
  safety_case.sh          # I-0108 evidence bundle generator
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

### 2.1) Ops/Infra validation
```bash
./scripts/validate_infra.sh
./scripts/load_smoke.sh
./scripts/dr_rehearsal.sh
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
  - `POST /v1/orders`
  - `DELETE /v1/orders/{orderId}`
  - `GET /v1/orders/{orderId}`
  - `POST /v1/smoke/trades`
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
  - `GET /v1/balances`
  - `POST /v1/admin/rebuild-balances`
  - `POST /v1/admin/invariants/check`
  - `GET /v1/admin/reconciliation/{symbol}`
  - `POST /v1/admin/corrections/requests`
  - `POST /v1/admin/corrections/{correctionId}/approve`
  - `POST /v1/admin/corrections/{correctionId}/apply`
- Postgres: `localhost:5432`
- Redpanda Kafka: `localhost:19092`
- Redpanda HTTP proxy: `localhost:18082`
- Redis: `localhost:6380`
- ClickHouse HTTP/TCP: `localhost:18123` / `localhost:19000`
- MinIO API/Console: `localhost:19002` / `localhost:19001`
- OTel collector OTLP gRPC/HTTP: `localhost:14317` / `localhost:14318`
- Prometheus: `localhost:19090`

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

Request headers for trading endpoints:
- `X-API-KEY`
- `X-TS` (epoch ms)
- `X-SIGNATURE` (HMAC-SHA256 of `METHOD\nPATH\nX-TS\nBODY`)
- `Idempotency-Key` (POST/DELETE required)

## OTel config (I-0102)
Edge env:
- `EDGE_OTEL_ENDPOINT=localhost:14317`
- `EDGE_OTEL_INSECURE=true`
- `EDGE_OTEL_SERVICE_NAME=edge-gateway`
- `EDGE_OTEL_SAMPLE_RATIO=1.0`

Ledger env:
- `LEDGER_OTEL_ENDPOINT=http://localhost:14318/v1/traces`
- `LEDGER_OTEL_SAMPLE_PROB=1.0`
