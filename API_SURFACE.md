# API_SURFACE.md — REST / WebSocket / gRPC / Events (v1)

This document defines external API contracts and internal service interfaces.

Contract source of truth:
- `contracts/proto/exchange/v1/*.proto`
- `buf lint` / `buf breaking` / `buf generate` are required gates.

Versioning rule:
- package suffix `v1` for non-breaking evolution
- breaking changes require a new package major (`v2`) with compatibility plan

---

## 1) External REST API (Edge Gateway)

Base: `/v1`

### Auth
- API key + signature (HMAC) for trading endpoints
- Headers:
  - `X-API-KEY`
  - `X-TS` (epoch ms)
  - `X-SIGNATURE`
  - `Idempotency-Key` (required for write)

### Orders
#### POST `/v1/orders`
Create order (LIMIT / MARKET)

Request (example)
```json
{
  "symbol": "BTC-KRW",
  "side": "BUY",
  "type": "LIMIT",
  "price": "100000000",
  "qty": "10000",
  "timeInForce": "GTC"
}
```

Response
```json
{
  "orderId": "ord_...",
  "status": "ACCEPTED",
  "symbol": "BTC-KRW",
  "seq": 1234567,
  "acceptedAt": 1730000000000
}
```

Errors (examples)
- `PRICE_BAND`
- `INSUFFICIENT_FUNDS`
- `MARKET_HALTED`
- `TOO_MANY_REQUESTS`

#### DELETE `/v1/orders/{orderId}`
Cancel order

Response includes latest `seq` and final status.

#### GET `/v1/orders/{orderId}`
Order status (includes executed vs settled status if enabled)

### Market data (REST)
#### GET `/v1/markets/{symbol}/trades?limit=...`
Recent trades (history read path: ClickHouse)

#### GET `/v1/markets/{symbol}/orderbook`
Orderbook snapshot (from Redis/cache or Edge snapshot service)
- query: `depth=20|50|200`

#### GET `/v1/markets/{symbol}/candles?interval=1m&from=...&to=...`
Candles history (ClickHouse)

---

## 2) External WebSocket API (Edge Gateway)

### Connection
- URL: `/ws`
- Protocol: JSON messages

### Subscribe message
```json
{ "op": "SUB", "channel": "trades", "symbol": "BTC-KRW" }
```

### Channels
- `trades:{symbol}`
- `book:{symbol}:{depth}` (depth=20/50/200)
- `ticker:{symbol}`
- `candles:{symbol}:{interval}` (interval=1m/5m/1h/1d)

### Event envelope
```json
{
  "type": "CandleUpdated",
  "symbol": "BTC-KRW",
  "seq": 1234567,
  "ts": 1730000000123,
  "data": { }
}
```

### CandleUpdated payload
```json
{
  "interval": "1m",
  "openTime": 1730000000000,
  "closeTime": 1730000059999,
  "open": "100000000",
  "high": "100010000",
  "low": "99990000",
  "close": "100005000",
  "volume": "12345",
  "tradeCount": 321,
  "isFinal": false
}
```

### Gap recovery
- Client sends last seen seq:
```json
{ "op": "RESUME", "symbol": "BTC-KRW", "lastSeq": 1234500 }
```
- Server responses:
  - if ok: continue deltas
  - if gap: send `Snapshot` then deltas

### Backpressure policy (must implement)
- per‑connection queue limit (e.g., 1–5MB)
- depth/candle updates are conflated (latest only)
- persistent slow client: close with code `SLOW_CONSUMER`

---

## 3) Internal gRPC (Edge ↔ Trading Core)

Service: `TradingCoreService`

### PlaceOrder
- request: `PlaceOrderCommand`
- response: `OrderAck`

### CancelOrder
- request: `CancelOrderCommand`
- response: `CancelAck`

### Admin controls
- `SetSymbolMode(symbol, mode)` where mode ∈ {NORMAL, CANCEL_ONLY, SOFT_HALT, HARD_HALT}
- `CancelAll(symbol)`

**Required fields on every command**
- `command_id`, `idempotency_key`, `user_id`, `symbol`, `ts_server`, `trace_id`

---

## 4) Events (Kafka/Redpanda)

Topic naming (suggested)
- `core.order-events.v1`
- `core.trade-events.v1`
- `core.book-events.v1`
- `md.candle-events.v1`
- `ledger.entry-events.v1` (optional)

### Core events
- `OrderAccepted`, `OrderRejected`
- `OrderCanceled`, `CancelRejected`
- `TradeExecuted`
- `BookDelta`
- `EngineCheckpoint`

### Market data events
- `CandleUpdated` (progress + final)
- `TickerUpdated` (24h rolling)

### Ledger events
- `LedgerEntryAppended`

**Event envelope (protobuf) must include**
- `event_id`, `event_version`
- `symbol`, `seq`
- `occurred_at`
- `correlation_id`, `causation_id`
