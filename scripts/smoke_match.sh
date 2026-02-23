#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/infra/compose/docker-compose.yml"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CORE_ADDR="0.0.0.0:55051"
EDGE_ADDR=":18081"
EDGE_BASE_URL="http://localhost:18081"
LEDGER_PORT="18082"
LEDGER_BASE_URL="http://localhost:18082"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"

core_log="/tmp/trading-core-smoke-match.log"
edge_log="/tmp/edge-gateway-smoke-match.log"
ledger_log="/tmp/ledger-service-smoke-match.log"
kafka_log="/tmp/kafka-consume-smoke-match.log"


require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}. ${hint}" >&2
    exit 1
  fi
}

require_cmd docker "Install Docker Desktop and ensure docker compose works."
require_cmd curl "Install curl (usually preinstalled on macOS)."
require_cmd cargo "Install Rust toolchain via rustup."
require_cmd go "Install Go via brew install go."
require_cmd java "Install JDK 17/21 and set JAVA_HOME."
require_cmd "${PYTHON_BIN}" "Install Python 3 (brew install python)."

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is not available. Install/update Docker Desktop." >&2
  exit 1
fi

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

cleanup() {
  if [[ -n "${KAFKA_PID:-}" ]] && kill -0 "${KAFKA_PID}" >/dev/null 2>&1; then
    kill "${KAFKA_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CORE_PID:-}" ]] && kill -0 "${CORE_PID}" >/dev/null 2>&1; then
    kill "${CORE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "${EDGE_PID}" >/dev/null 2>&1; then
    kill "${EDGE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LEDGER_PID:-}" ]] && kill -0 "${LEDGER_PID}" >/dev/null 2>&1; then
    kill "${LEDGER_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

docker compose -f "${COMPOSE_FILE}" up -d postgres redpanda redpanda-init redis

echo "Waiting for Redpanda..."
for _ in {1..40}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

RUN_ID="$(date +%s)"
CORE_WAL_DIR="/tmp/trading-core/smoke-match-${RUN_ID}/wal"
CORE_OUTBOX_DIR="/tmp/trading-core/smoke-match-${RUN_ID}/outbox"
LEDGER_DB_NAME="exchange_ledger_smoke_match"
mkdir -p "${CORE_WAL_DIR}" "${CORE_OUTBOX_DIR}"

CORE_CFLAGS=""
CORE_CXXFLAGS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  CORE_CFLAGS="-isysroot ${SDKROOT}"
  CORE_CXXFLAGS="-isysroot ${SDKROOT} -I${SDKROOT}/usr/include/c++/v1"
fi

echo "Starting trading-core..."
CFLAGS="${CORE_CFLAGS}" \
CXXFLAGS="${CORE_CXXFLAGS}" \
CORE_GRPC_ADDR="${CORE_ADDR}" \
CORE_SYMBOL="BTC-KRW" \
CORE_WAL_DIR="${CORE_WAL_DIR}" \
CORE_OUTBOX_DIR="${CORE_OUTBOX_DIR}" \
CORE_KAFKA_BROKERS="localhost:29092" \
CORE_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
CORE_STUB_TRADES="false" \
cargo run -p trading-core --bin trading-core >"${core_log}" 2>&1 &
CORE_PID=$!

echo "[checkpoint-a] waiting for trading-core gRPC port ${CORE_ADDR}..."
for _ in {1..40}; do
  if (echo > /dev/tcp/localhost/55051) >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! (echo > /dev/tcp/localhost/55051) >/dev/null 2>&1; then
  echo "trading-core gRPC is not ready" >&2
  cat "${core_log}" >&2
  exit 1
fi

docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d postgres -c "DROP DATABASE IF EXISTS ${LEDGER_DB_NAME} WITH (FORCE);" >/dev/null
docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d postgres -c "CREATE DATABASE ${LEDGER_DB_NAME};" >/dev/null

echo "Starting edge-gateway..."
echo "[checkpoint-b] placing orders through Edge and verifying Core receives PlaceOrder"
EDGE_ADDR="${EDGE_ADDR}" \
EDGE_DISABLE_DB="true" \
EDGE_DISABLE_CORE="false" \
EDGE_CORE_ADDR="localhost:55051" \
EDGE_KAFKA_BROKERS="localhost:29092" \
EDGE_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
EDGE_KAFKA_GROUP_ID="edge-smoke-match-${RUN_ID}" \
EDGE_SEED_MARKET_DATA="false" \
EDGE_API_SECRETS="" \
go run ./services/edge-gateway/cmd/edge-gateway >"${edge_log}" 2>&1 &
EDGE_PID=$!

echo "Starting ledger-service..."
LEDGER_KAFKA_ENABLED="true" \
LEDGER_KAFKA_BOOTSTRAP="localhost:29092" \
LEDGER_KAFKA_GROUP_ID="ledger-smoke-match-${RUN_ID}" \
LEDGER_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
LEDGER_DB_URL="jdbc:postgresql://localhost:25432/${LEDGER_DB_NAME}" \
LEDGER_DB_USER="exchange" \
LEDGER_DB_PASSWORD="exchange" \
LEDGER_FLYWAY_BASELINE_ON_MIGRATE="false" \
LEDGER_GUARD_ENABLED="false" \
LEDGER_PORT="${LEDGER_PORT}" \
./gradlew :services:ledger-service:bootRun --quiet >"${ledger_log}" 2>&1 &
LEDGER_PID=$!

echo "Waiting for edge-gateway..."
for _ in {1..40}; do
  if curl -sf "${EDGE_BASE_URL}/readyz" >/dev/null; then
    break
  fi
  sleep 1
done

echo "Waiting for ledger-service..."
for _ in {1..80}; do
  if curl -sf "${LEDGER_BASE_URL}/readyz" >/dev/null; then
    break
  fi
  sleep 1
done

if ! curl -sf "${EDGE_BASE_URL}/readyz" >/dev/null; then
  echo "edge-gateway is not ready" >&2
  cat "${edge_log}" >&2
  exit 1
fi

if ! curl -sf "${LEDGER_BASE_URL}/readyz" >/dev/null; then
  echo "ledger-service is not ready" >&2
  cat "${ledger_log}" >&2
  exit 1
fi

KAFKA_CAPTURE="/tmp/smoke-match-trade-${RUN_ID}.json"
docker compose -f "${COMPOSE_FILE}" exec -T redpanda \
  rpk topic consume core.trade-events.v1 -n 1 -o end -f '%v\n' >"${KAFKA_CAPTURE}" 2>"${kafka_log}" &
KAFKA_PID=$!
sleep 1

EMAIL="smoke.match.${RUN_ID}@example.com"
SIGNUP_RESP="$(curl -fsS -X POST "${EDGE_BASE_URL}/v1/auth/signup" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"password1234\"}")"

SESSION_TOKEN="$(
SIGNUP_RESP="${SIGNUP_RESP}" "${PYTHON_BIN}" - <<'PY'
import json, os
payload = json.loads(os.environ["SIGNUP_RESP"])
print(payload.get("sessionToken", ""))
PY
)"

if [[ -z "${SESSION_TOKEN}" ]]; then
  echo "missing session token from signup response: ${SIGNUP_RESP}" >&2
  exit 1
fi

BUY_IDEM="smoke-buy-${RUN_ID}"
SELL_IDEM="smoke-sell-${RUN_ID}"

BUY_RESP="$(curl -fsS -X POST "${EDGE_BASE_URL}/v1/orders" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H "Idempotency-Key: ${BUY_IDEM}" \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"10000000","qty":"1","timeInForce":"GTC"}')"

SELL_RESP="$(curl -fsS -X POST "${EDGE_BASE_URL}/v1/orders" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H "Idempotency-Key: ${SELL_IDEM}" \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"BTC-KRW","side":"SELL","type":"LIMIT","price":"9000000","qty":"1","timeInForce":"GTC"}')"

read -r BUY_ORDER_ID BUY_STATUS <<<"$(
BUY_RESP="${BUY_RESP}" "${PYTHON_BIN}" - <<'PY'
import json, os
payload = json.loads(os.environ["BUY_RESP"])
print(payload.get("orderId", ""), payload.get("status", ""))
PY
)"

read -r SELL_ORDER_ID SELL_STATUS <<<"$(
SELL_RESP="${SELL_RESP}" "${PYTHON_BIN}" - <<'PY'
import json, os
payload = json.loads(os.environ["SELL_RESP"])
print(payload.get("orderId", ""), payload.get("status", ""))
PY
)"

if [[ -z "${BUY_ORDER_ID}" || -z "${SELL_ORDER_ID}" ]]; then
  echo "missing orderId from responses" >&2
  echo "buy=${BUY_RESP}" >&2
  echo "sell=${SELL_RESP}" >&2
  exit 1
fi

if [[ "${BUY_STATUS}" != "FILLED" && "${SELL_STATUS}" != "FILLED" ]]; then
  echo "expected at least one FILLED order; buy=${BUY_STATUS} sell=${SELL_STATUS}" >&2
  exit 1
fi


if ! grep -q "place_order" "${core_log}"; then
  echo "core log does not contain place_order invocation; expected Edge->Core traffic" >&2
  tail -n 120 "${core_log}" >&2 || true
  exit 1
fi
if ! grep -Eq "${BUY_ORDER_ID}|${SELL_ORDER_ID}" "${core_log}"; then
  echo "core log does not show submitted order ids; expected BUY/SELL to reach Core" >&2
  tail -n 120 "${core_log}" >&2 || true
  exit 1
fi

echo "[checkpoint-c] waiting for TradeExecuted on topic core.trade-events.v1"
for _ in {1..30}; do
  if ! kill -0 "${KAFKA_PID}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if kill -0 "${KAFKA_PID}" >/dev/null 2>&1; then
  echo "timed out waiting for TradeExecuted on Kafka" >&2
  kill "${KAFKA_PID}" >/dev/null 2>&1 || true
  exit 1
fi
wait "${KAFKA_PID}"

TRADE_ID="$(
BUY_ORDER_ID="${BUY_ORDER_ID}" SELL_ORDER_ID="${SELL_ORDER_ID}" KAFKA_CAPTURE="${KAFKA_CAPTURE}" "${PYTHON_BIN}" - <<'PY'
import json, os, sys
with open(os.environ["KAFKA_CAPTURE"], "r", encoding="utf-8") as f:
    raw = f.read().strip()
if not raw:
    print("no kafka payload", file=sys.stderr)
    sys.exit(1)
payload = json.loads(raw)
maker = payload.get("makerOrderId")
taker = payload.get("takerOrderId")
expected = {os.environ["BUY_ORDER_ID"], os.environ["SELL_ORDER_ID"]}
if {maker, taker} != expected:
    print(f"unexpected maker/taker maker={maker} taker={taker} expected={expected}", file=sys.stderr)
    sys.exit(1)
trade_id = payload.get("tradeId", "")
if not trade_id:
    print("missing tradeId", file=sys.stderr)
    sys.exit(1)
print(trade_id)
PY
)"

echo "[checkpoint-d] waiting for ledger REST to reflect tradeId=${TRADE_ID}"
found="false"
for _ in {1..60}; do
  code="$(ledger_admin_curl -s -o /dev/null -w '%{http_code}' "${LEDGER_BASE_URL}/v1/admin/trades/${TRADE_ID}")"
  if [[ "${code}" == "200" ]]; then
    found="true"
    break
  fi
  sleep 1
done

if [[ "${found}" != "true" ]]; then
  echo "ledger did not apply trade ${TRADE_ID}" >&2
  cat "${ledger_log}" >&2
  exit 1
fi

echo "smoke_match_success=true trade_id=${TRADE_ID} buy_status=${BUY_STATUS} sell_status=${SELL_STATUS}"
echo "checkpoint_a=core_grpc_listening checkpoint_b=edge_to_core_placeorder checkpoint_c=tradeexecuted_on_kafka checkpoint_d=ledger_trade_visible"
