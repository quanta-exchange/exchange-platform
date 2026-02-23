#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/infra/compose/docker-compose.yml"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"

core_log="/tmp/trading-core-e2e.log"
edge_log="/tmp/edge-gateway-e2e.log"
ledger_log="/tmp/ledger-service-e2e.log"

CORE_CFLAGS=""
CORE_CXXFLAGS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  CORE_CFLAGS="-isysroot ${SDKROOT}"
  CORE_CXXFLAGS="-isysroot ${SDKROOT} -I${SDKROOT}/usr/include/c++/v1"
fi

cleanup() {
  if [[ -n "${CORE_PID:-}" ]]; then
    kill "${CORE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${EDGE_PID:-}" ]]; then
    kill "${EDGE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LEDGER_PID:-}" ]]; then
    kill "${LEDGER_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

LEDGER_ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  LEDGER_ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

ledger_admin_curl() {
  if [[ "${#LEDGER_ADMIN_HEADERS[@]}" -gt 0 ]]; then
    curl "${LEDGER_ADMIN_HEADERS[@]}" "$@"
    return
  fi
  curl "$@"
}

docker compose -f "${COMPOSE_FILE}" up -d

echo "Waiting for Redpanda..."
for _ in {1..30}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "Starting trading-core..."
CFLAGS="${CORE_CFLAGS}" \
CXXFLAGS="${CORE_CXXFLAGS}" \
CORE_GRPC_ADDR="0.0.0.0:50051" \
CORE_KAFKA_BROKERS="localhost:29092" \
CORE_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
CORE_STUB_TRADES="true" \
cargo run -p trading-core --bin trading-core >"${core_log}" 2>&1 &
CORE_PID=$!

echo "Starting edge-gateway..."
EDGE_ADDR=":8081" \
EDGE_DISABLE_DB="true" \
EDGE_CORE_ADDR="localhost:50051" \
EDGE_ALLOW_INSECURE_NO_AUTH="true" \
EDGE_API_SECRETS="" \
go run ./services/edge-gateway/cmd/edge-gateway >"${edge_log}" 2>&1 &
EDGE_PID=$!

echo "Starting ledger-service..."
LEDGER_KAFKA_ENABLED="true" \
LEDGER_KAFKA_BOOTSTRAP="localhost:29092" \
LEDGER_DB_URL="jdbc:postgresql://localhost:25432/exchange" \
LEDGER_DB_USER="exchange" \
LEDGER_DB_PASSWORD="exchange" \
./gradlew :services:ledger-service:bootRun >"${ledger_log}" 2>&1 &
LEDGER_PID=$!

echo "Waiting for edge-gateway..."
for _ in {1..30}; do
  if curl -sf http://localhost:8081/healthz >/dev/null; then
    break
  fi
  sleep 1
done

echo "Waiting for ledger-service..."
for _ in {1..40}; do
  if curl -sf http://localhost:8082/healthz >/dev/null; then
    break
  fi
  sleep 2
done

order_payload='{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}'
order_resp="$(curl -sf -X POST http://localhost:8081/v1/orders \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: e2e-1' \
  -d "${order_payload}")"

ORDER_RESP="${order_resp}" python - <<'PY'
import json, os, sys
resp = json.loads(os.environ["ORDER_RESP"])
if not resp.get("orderId") or resp.get("seq") is None:
    print("missing orderId/seq in response", resp)
    sys.exit(1)
PY

trade_json="$(docker compose -f "${COMPOSE_FILE}" exec -T redpanda \
  rpk topic consume core.trade-events.v1 -n 1 -f '%v\n' -o new)"

TRADE_JSON="${trade_json}" trade_id="$(python - <<'PY'
import json, os
payload = json.loads(os.environ["TRADE_JSON"])
print(payload["tradeId"])
PY
)"

echo "Waiting for ledger entry for trade ${trade_id}..."
found="false"
for _ in {1..30}; do
  status="$(ledger_admin_curl -s -o /dev/null -w '%{http_code}' "http://localhost:8082/v1/admin/trades/${trade_id}")"
  if [[ "${status}" == "200" ]]; then
    found="true"
    break
  fi
  sleep 1
done

if [[ "${found}" != "true" ]]; then
  echo "ledger did not record trade ${trade_id}" >&2
  exit 1
fi

echo "E2E smoke OK: order accepted, trade event published, ledger applied."
