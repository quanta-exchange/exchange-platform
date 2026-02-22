#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EDGE_LOG="/tmp/edge-gateway-smoke-g3.log"
LEDGER_LOG="/tmp/ledger-service-smoke-g3.log"
WS_LOG="/tmp/ws-events-smoke-g3.log"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"

cleanup() {
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "$EDGE_PID" 2>/dev/null; then
    kill "$EDGE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LEDGER_PID:-}" ]] && kill -0 "$LEDGER_PID" 2>/dev/null; then
    kill "$LEDGER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

docker compose -f infra/compose/docker-compose.yml up -d postgres redpanda redpanda-init redis clickhouse minio minio-init otel-collector prometheus

docker compose -f infra/compose/docker-compose.yml exec -T postgres \
  psql -U exchange -d postgres -c "DROP DATABASE IF EXISTS exchange_ledger WITH (FORCE);" >/dev/null
docker compose -f infra/compose/docker-compose.yml exec -T postgres \
  psql -U exchange -d postgres -c "CREATE DATABASE exchange_ledger;" >/dev/null

LEDGER_DB_URL="jdbc:postgresql://localhost:25432/exchange_ledger" \
LEDGER_DB_USER="exchange" \
LEDGER_DB_PASSWORD="exchange" \
LEDGER_KAFKA_ENABLED="false" \
LEDGER_GUARD_ENABLED="false" \
LEDGER_PORT="8082" \
./gradlew :services:ledger-service:bootRun --quiet >"$LEDGER_LOG" 2>&1 &
LEDGER_PID=$!

EDGE_ADDR=":8081" \
EDGE_DB_DSN="postgres://exchange:exchange@localhost:25432/exchange?sslmode=disable" \
go run ./services/edge-gateway/cmd/edge-gateway >"$EDGE_LOG" 2>&1 &
EDGE_PID=$!

for _ in {1..60}; do
  if curl -fsS "http://localhost:8082/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://localhost:8082/readyz" >/dev/null 2>&1; then
  echo "ledger-service readiness failed"
  cat "$LEDGER_LOG"
  exit 1
fi

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

TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_ID="$(date -u +%s)"

curl -fsS -X POST "http://localhost:8082/v1/admin/adjustments" \
  "${ADMIN_HEADERS[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"envelope\":{\"eventId\":\"evt-seed-1-$RUN_ID\",\"eventVersion\":1,\"symbol\":\"BTC-KRW\",\"seq\":1,\"occurredAt\":\"$TS\",\"correlationId\":\"corr-seed-1-$RUN_ID\",\"causationId\":\"cause-seed-1-$RUN_ID\"},\"referenceId\":\"seed-buyer-g3-$RUN_ID\",\"userId\":\"buyer\",\"currency\":\"KRW\",\"amountDelta\":200000000}" >/dev/null

curl -fsS -X POST "http://localhost:8082/v1/admin/adjustments" \
  "${ADMIN_HEADERS[@]}" \
  -H 'Content-Type: application/json' \
  -d "{\"envelope\":{\"eventId\":\"evt-seed-2-$RUN_ID\",\"eventVersion\":1,\"symbol\":\"BTC-KRW\",\"seq\":2,\"occurredAt\":\"$TS\",\"correlationId\":\"corr-seed-2-$RUN_ID\",\"causationId\":\"cause-seed-2-$RUN_ID\"},\"referenceId\":\"seed-seller-g3-$RUN_ID\",\"userId\":\"seller\",\"currency\":\"BTC\",\"amountDelta\":10000}" >/dev/null

curl -fsS -X POST "http://localhost:8082/v1/internal/orders/reserve" \
  -H 'Content-Type: application/json' \
  -d "{\"envelope\":{\"eventId\":\"evt-reserve-1-$RUN_ID\",\"eventVersion\":1,\"symbol\":\"BTC-KRW\",\"seq\":3,\"occurredAt\":\"$TS\",\"correlationId\":\"corr-reserve-1-$RUN_ID\",\"causationId\":\"cause-reserve-1-$RUN_ID\"},\"orderId\":\"ord-g3-buy-1-$RUN_ID\",\"userId\":\"buyer\",\"side\":\"BUY\",\"amount\":100000000}" >/dev/null

curl -fsS -X POST "http://localhost:8082/v1/internal/orders/reserve" \
  -H 'Content-Type: application/json' \
  -d "{\"envelope\":{\"eventId\":\"evt-reserve-2-$RUN_ID\",\"eventVersion\":1,\"symbol\":\"BTC-KRW\",\"seq\":4,\"occurredAt\":\"$TS\",\"correlationId\":\"corr-reserve-2-$RUN_ID\",\"causationId\":\"cause-reserve-2-$RUN_ID\"},\"orderId\":\"ord-g3-sell-1-$RUN_ID\",\"userId\":\"seller\",\"side\":\"SELL\",\"amount\":10000}" >/dev/null

go run ./scripts/ws_probe.go -url ws://localhost:8081/ws -count 2 -out "$WS_LOG" &
WS_PID=$!
sleep 1

ORDER_ACK="$(curl -fsS -X POST "http://localhost:8081/v1/orders" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: g3-order-1-$RUN_ID" \
  -d '{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100000000","qty":"10000","timeInForce":"GTC"}')"

echo "order_ack=$ORDER_ACK"

SETTLE_ACK="$(curl -fsS -X POST "http://localhost:8082/v1/internal/trades/executed" \
  -H 'Content-Type: application/json' \
  -d "{\"envelope\":{\"eventId\":\"evt-trade-g3-1-$RUN_ID\",\"eventVersion\":1,\"symbol\":\"BTC-KRW\",\"seq\":10,\"occurredAt\":\"$TS\",\"correlationId\":\"corr-trade-g3-1-$RUN_ID\",\"causationId\":\"cause-trade-g3-1-$RUN_ID\"},\"tradeId\":\"trade-smoke-g3-1-$RUN_ID\",\"buyerUserId\":\"buyer\",\"sellerUserId\":\"seller\",\"price\":100000000,\"quantity\":10000,\"quoteAmount\":100000000}")"

echo "ledger_settlement_ack=$SETTLE_ACK"

WS_ACK="$(curl -fsS -X POST "http://localhost:8081/v1/smoke/trades" \
  -H 'Content-Type: application/json' \
  -d "{\"tradeId\":\"trade-smoke-g3-1-$RUN_ID\",\"symbol\":\"BTC-KRW\",\"price\":\"100000000\",\"qty\":\"10000\"}")"

echo "edge_ws_ack=$WS_ACK"

wait "$WS_PID"

LEDGER_ROW_COUNT="$(docker compose -f infra/compose/docker-compose.yml exec -T postgres \
  psql -U exchange -d exchange_ledger -tAc "SELECT COUNT(*) FROM ledger_entries WHERE reference_type = 'TRADE' AND reference_id = 'trade-smoke-g3-1-$RUN_ID';" | tr -d '[:space:]')"

if [[ "$LEDGER_ROW_COUNT" != "1" ]]; then
  echo "expected ledger trade row count=1, got=$LEDGER_ROW_COUNT"
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

echo "smoke_g3_success=true"
echo "ws_events:"
cat "$WS_LOG"
