#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date +%s)"
EDGE_PORT="${EDGE_PORT:-$((26000 + RANDOM % 2000))}"
EDGE_URL="http://localhost:${EDGE_PORT}"
WS_URL="ws://localhost:${EDGE_PORT}/ws"
EDGE_LOG="/tmp/edge-gateway-ws-smoke-${RUN_ID}.log"
WS_CLIENT_LOG="/tmp/ws-slow-client-smoke-${RUN_ID}.log"
WS_EVENTS_LOG="/tmp/ws-slow-events-smoke-${RUN_ID}.jsonl"
WS_QUEUE_SIZE="${WS_QUEUE_SIZE:-2}"
TRADE_BURST="${TRADE_BURST:-1200}"
PARALLEL_POSTS="${PARALLEL_POSTS:-40}"

require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}. ${hint}" >&2
    exit 1
  fi
}

require_cmd go "Install Go toolchain."
require_cmd curl "Install curl."

cleanup() {
  if [[ -n "${WS_PID:-}" ]] && kill -0 "${WS_PID}" >/dev/null 2>&1; then
    kill "${WS_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "${EDGE_PID}" >/dev/null 2>&1; then
    kill "${EDGE_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "${ROOT_DIR}"

EDGE_ADDR=":${EDGE_PORT}" \
EDGE_DISABLE_DB="true" \
EDGE_DISABLE_CORE="true" \
EDGE_SEED_MARKET_DATA="false" \
EDGE_ENABLE_SMOKE_ROUTES="true" \
EDGE_ALLOW_INSECURE_NO_AUTH="true" \
EDGE_API_SECRETS="" \
EDGE_WS_QUEUE_SIZE="${WS_QUEUE_SIZE}" \
EDGE_WS_WRITE_DELAY_MS="40" \
go run ./services/edge-gateway/cmd/edge-gateway >"${EDGE_LOG}" 2>&1 &
EDGE_PID=$!

for _ in {1..60}; do
  if curl -fsS "${EDGE_URL}/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "${EDGE_URL}/readyz" >/dev/null 2>&1; then
  echo "edge-gateway readiness failed" >&2
  tail -n 120 "${EDGE_LOG}" >&2 || true
  exit 1
fi

go run ./scripts/ws_slow_client.go \
  -url "${WS_URL}" \
  -symbol "BTC-KRW" \
  -read-sleep "500ms" \
  -initial-pause "5s" \
  -timeout "40s" \
  -expect-close-code "4001" \
  -out "${WS_EVENTS_LOG}" >"${WS_CLIENT_LOG}" 2>&1 &
WS_PID=$!

sleep 1

FILLER="$(printf 'x%.0s' $(seq 1 4096))"
export EDGE_URL RUN_ID FILLER

flood_trades() {
  local start="$1"
  local count="$2"
  local end="$((start + count - 1))"
  seq "${start}" "${end}" | xargs -I{} -P "${PARALLEL_POSTS}" bash -c '
    i="$1"
    curl -fsS -X POST "${EDGE_URL}/v1/smoke/trades" \
      -H "Content-Type: application/json" \
      -d "{\"tradeId\":\"ws-smoke-${RUN_ID}-${i}-${FILLER}\",\"symbol\":\"BTC-KRW\",\"price\":\"100\",\"qty\":\"1\"}" >/dev/null
  ' _ {}
}

echo "[ws-smoke] flood trades burst-1 count=${TRADE_BURST}"
flood_trades 1 "${TRADE_BURST}"
if kill -0 "${WS_PID}" >/dev/null 2>&1; then
  echo "[ws-smoke] slow client still open; running burst-2"
  flood_trades "$((TRADE_BURST + 1))" "${TRADE_BURST}"
fi
if kill -0 "${WS_PID}" >/dev/null 2>&1; then
  echo "[ws-smoke] slow client still open; running burst-3"
  flood_trades "$((TRADE_BURST * 2 + 1))" "${TRADE_BURST}"
fi

if ! wait "${WS_PID}"; then
  echo "slow websocket client did not observe expected close behavior" >&2
  cat "${WS_CLIENT_LOG}" >&2 || true
  tail -n 120 "${EDGE_LOG}" >&2 || true
  exit 1
fi

METRICS="$(curl -fsS "${EDGE_URL}/metrics")"
metric_value() {
  local key="$1"
  echo "${METRICS}" | awk -v metric="${key}" '$1 == metric {print $2; exit}'
}

WS_SLOW_CLOSES="$(metric_value ws_slow_closes)"
WS_DROPPED_MSGS="$(metric_value ws_dropped_msgs)"
WS_QUEUE_P99="$(metric_value ws_send_queue_p99)"

if [[ -z "${WS_SLOW_CLOSES}" || -z "${WS_DROPPED_MSGS}" || -z "${WS_QUEUE_P99}" ]]; then
  echo "missing ws metrics from /metrics output" >&2
  echo "${METRICS}" >&2
  exit 1
fi

if (( ${WS_SLOW_CLOSES%.*} < 1 )); then
  echo "expected ws_slow_closes >= 1, got ${WS_SLOW_CLOSES}" >&2
  exit 1
fi
if (( ${WS_DROPPED_MSGS%.*} < 1 )); then
  echo "expected ws_dropped_msgs >= 1, got ${WS_DROPPED_MSGS}" >&2
  exit 1
fi
if ! grep -q '^ws_close_code=4001$' "${WS_CLIENT_LOG}"; then
  echo "slow client close code mismatch; expected 4001" >&2
  cat "${WS_CLIENT_LOG}" >&2 || true
  exit 1
fi

echo "ws_smoke_success=true"
echo "ws_slow_closes=${WS_SLOW_CLOSES}"
echo "ws_dropped_msgs=${WS_DROPPED_MSGS}"
echo "ws_send_queue_p99=${WS_QUEUE_P99}"
