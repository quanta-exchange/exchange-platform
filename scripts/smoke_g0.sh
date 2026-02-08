#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EDGE_LOG="/tmp/edge-gateway-smoke.log"
WS_LOG="/tmp/ws-events-smoke.log"

cleanup() {
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "$EDGE_PID" 2>/dev/null; then
    kill "$EDGE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

docker compose -f infra/compose/docker-compose.yml up -d postgres redpanda redpanda-init redis clickhouse minio minio-init otel-collector prometheus

EDGE_ADDR=":8081" EDGE_DB_DSN="postgres://exchange:exchange@localhost:5432/exchange?sslmode=disable" go run ./services/edge-gateway/cmd/edge-gateway >"$EDGE_LOG" 2>&1 &
EDGE_PID=$!

for _ in {1..30}; do
  if curl -fsS "http://localhost:8081/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://localhost:8081/readyz" >/dev/null 2>&1; then
  echo "edge-gateway readiness failed"
  cat "$EDGE_LOG"
  exit 1
fi

go run ./scripts/ws_probe.go -url ws://localhost:8081/ws -count 2 -out "$WS_LOG" &
WS_PID=$!
sleep 1

ORDER_ACK="$(curl -fsS -X POST "http://localhost:8081/v1/orders" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: smoke-order-1' \
  -d '{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100000000","qty":"10000","timeInForce":"GTC"}')"

echo "order_ack=$ORDER_ACK"

SETTLE_ACK="$(curl -fsS -X POST "http://localhost:8081/v1/smoke/trades" \
  -H 'Content-Type: application/json' \
  -d '{"tradeId":"trade-smoke-1","symbol":"BTC-KRW","price":"100000000","qty":"10000"}')"

echo "settlement_ack=$SETTLE_ACK"

wait "$WS_PID"

ROW_COUNT="$(docker compose -f infra/compose/docker-compose.yml exec -T postgres \
  psql -U exchange -d exchange -tAc "SELECT COUNT(*) FROM smoke_ledger_entries WHERE trade_id = 'trade-smoke-1';" | tr -d '[:space:]')"

if [[ "$ROW_COUNT" != "1" ]]; then
  echo "expected ledger row count=1, got=$ROW_COUNT"
  exit 1
fi

if ! grep -q '"type":"TradeExecuted"' "$WS_LOG"; then
  echo "missing TradeExecuted WS event"
  cat "$WS_LOG"
  exit 1
fi
if ! grep -q '"type":"CandleUpdated"' "$WS_LOG"; then
  echo "missing CandleUpdated WS event"
  cat "$WS_LOG"
  exit 1
fi

echo "smoke_g0_success=true"
echo "ws_events:"
cat "$WS_LOG"
