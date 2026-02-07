# Plans.md — Crypto Exchange (Spot) — Big‑Tech Monorepo Plan (Production)

> **Locked stack**
> 1) Trading Core (Matching/Risk hot‑path) = **Rust**
> 2) Edge Gateway (REST + WS fan‑out) = **Go**
> 3) Ledger/Accounts/Settlement = **Kotlin + Spring Boot + PostgreSQL**
> 4) Event Log = **Kafka/Redpanda + Protobuf**
> 5) Streaming = **Flink**
> 6) Cache = **Redis**, History/Analytics = **ClickHouse**, Archive = **S3**
> 7) Infra = **Kubernetes + OpenTelemetry + GitOps + KMS/HSM**

---

## 0. Product scope

### Launch‑1 (must ship)
- Spot trading: `LIMIT`, `MARKET`, `CANCEL`
- Symbol set: 3–10 symbols (hot symbol isolation supported)
- Real‑time market data:
  - trades, ticker(24h), orderbook (snapshot + delta), candles (1m base, 5m/1h rollups)
- Ledger:
  - **double‑entry**, **append‑only**, **idempotent settlement**
  - available/hold(Reserve) model
- Admin controls:
  - symbol `HALT` / `CANCEL_ONLY`, cancel‑all, rate limit overrides, safety switches
- Observability + Ops:
  - OTel traces/metrics/logs, SLO dashboards, alerts, runbooks
- DR:
  - backups + restore rehearsal, active‑passive for Trading Core

### Not in Launch‑1 (planned)
- Derivatives / margin / lending
- Advanced order types: stop/OCO/iceberg, GTT
- Multi‑region active‑active
- Full custody (deposits/withdrawals, signing, HSM) — add after Gate with extra controls

---

## 1. Non‑negotiable safety rules

1) **Ledger is the only source of truth**  
   - append‑only; corrections only via reversal/adjustment entries.

2) **Trading Core has no synchronous DB calls on hot path**  
   - deterministic, per‑symbol single‑writer event loop.

3) **Commit line is explicit**
   - An order is **Executed** only after WAL durable write.
   - Settlement is **at‑least‑once + idempotent**.

4) **Every event carries**
   - `event_id`, `event_version`, `symbol`, `seq`, `occurred_at`, `correlation_id`, `causation_id`.

5) **Slow clients never degrade the system**
   - WS backpressure, per‑connection queue limit, conflation, disconnect policy.

6) **Recovery is replayable**
   - WAL + snapshot + Kafka replay + ledger rebuild tools.

---

## 2. SLO / latency budgets (initial targets)

### Trading API
- Place/Cancel ACK: p50 < 10ms, p99 < 50ms (same region)
- Error rate: < 0.1% (steady state)

### Core
- Engine loop (command→event): p99 < 5ms
- Durable publish (WAL→outbox): p99 < 20ms
- Settlement lag (trade→ledger applied): p99 < 200ms

### Market data
- Trade→WS publish: p99 < 100ms
- Orderbook delta: 50–200ms conflation
- Candle updates: 250ms–1s (progress), close boundary emits `is_final=true`

### DR
- Ledger: RPO=0, RTO < 30min (Launch‑1)
- Market data/read models: RPO allowed, RTO < 10min

---

## 3. Architecture overview

- **Trading Core (Rust)**
  - command ingress (from Edge), risk hot‑path, matching
  - WAL + snapshot + replay
  - emits: TradeExecuted, OrderAccepted/Rejected, BookDelta, EngineCheckpoint
- **Edge Gateway (Go)**
  - REST API, authentication, signature verification, rate limit, request tracing
  - WS fan‑out: trades, book, ticker, candles
  - snapshot + delta + seq gap recovery
- **Ledger Service (Kotlin/Spring)**
  - double‑entry ledger append, idempotency store
  - balances materialization + rebuild tooling
  - reconciliation: engine seq ↔ ledger coverage
- **Kafka/Redpanda**
  - authoritative event log for fan‑out and replay
- **Flink**
  - streaming aggregates: candles, ticker(24h), anomaly signals
- **Redis / ClickHouse / S3**
  - hot snapshot cache / analytics history / archive
- **Kubernetes + OTel + GitOps**
  - consistent deployments, observability, controlled change management

---

## 4. Milestones & Gates (Go/No‑Go)

### Gate G0 — Repo/Contracts/Infra Ready
- buf lint + breaking check in CI
- compose infra local‑dev: postgres/kafka/redis/clickhouse/otel
- path‑based CI (only affected modules)

### Gate G1 — Trading Kernel Correctness
- golden test vectors ≥ 20 (matching + ledger semantics)
- WAL durable‑before‑publish proven by tests
- replay determinism: same WAL → same state hash

### Gate G2 — Market Data Production‑grade
- WS snapshot+delta, gap recovery, throttling/backpressure enforced
- hot cache strategy + history query path
- load test: WS fan‑out stable under peak connections

### Gate G3 — Ledger Safety
- double‑entry invariants guard + alerts
- idempotent settlement
- balances MV rebuild + reconciliation tooling

### Gate G4 — Launch Readiness
- load tests (orders + WS) + regression thresholds
- chaos/failover rehearsal (engine crash, kafka outage, pg failover)
- DR backup/restore rehearsal report
- runbooks + oncall readiness

---

## 5. Backlog management

- Source of truth: `tasks/backlog/*.md`
- Ticket prefixes:
  - `B-` Backend services (Rust/Go/Kotlin/Flink)
  - `I-` Infra/Platform/SRE/SecOps
  - `A-` Admin console (optional Launch‑1)
  - `U-` User UI (optional Launch‑1)
- Definition of Done (DoD) per ticket:
  - functional AC + edge cases
  - observability (metrics/logs/traces)
  - tests (unit/integration/property/load as applicable)
  - rollback plan + runbook update

---

## 6. Risk register (always on)

- split‑brain / dual leader → fencing token + consensus lease
- settlement lag / backlog → throttle/halt policy
- WS fan‑out overload → per‑conn limits + conflation + close slow clients
- rounding/precision → min‑unit integer, fee versioning, golden tests
- data tampering → hash‑chained WAL roots, restricted prod access
