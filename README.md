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
  - `GET /ws`
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
