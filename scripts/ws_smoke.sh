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
OUT_DIR="${OUT_DIR:-build/ws}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/ws-smoke.json}"

mkdir -p "${OUT_DIR}"

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
CLOSE_CODE="$(grep -E '^ws_close_code=' "${WS_CLIENT_LOG}" | tail -n 1 | cut -d= -f2 || true)"
if [[ "${CLOSE_CODE}" != "4001" ]]; then
  echo "slow client close code mismatch; expected 4001" >&2
  cat "${WS_CLIENT_LOG}" >&2 || true
  exit 1
fi

REPORT_FILE="${REPORT_FILE}" \
RUN_ID="${RUN_ID}" \
EDGE_URL="${EDGE_URL}" \
WS_URL="${WS_URL}" \
WS_QUEUE_SIZE="${WS_QUEUE_SIZE}" \
TRADE_BURST="${TRADE_BURST}" \
PARALLEL_POSTS="${PARALLEL_POSTS}" \
WS_SLOW_CLOSES="${WS_SLOW_CLOSES}" \
WS_DROPPED_MSGS="${WS_DROPPED_MSGS}" \
WS_QUEUE_P99="${WS_QUEUE_P99}" \
CLOSE_CODE="${CLOSE_CODE}" \
EDGE_LOG="${EDGE_LOG}" \
WS_CLIENT_LOG="${WS_CLIENT_LOG}" \
WS_EVENTS_LOG="${WS_EVENTS_LOG}" \
python3 - <<'PY'
import json
import os
from datetime import datetime, timezone

report = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": os.environ["RUN_ID"],
    "ok": True,
    "edge_url": os.environ["EDGE_URL"],
    "ws_url": os.environ["WS_URL"],
    "settings": {
        "ws_queue_size": int(os.environ["WS_QUEUE_SIZE"]),
        "trade_burst": int(os.environ["TRADE_BURST"]),
        "parallel_posts": int(os.environ["PARALLEL_POSTS"]),
    },
    "metrics": {
        "ws_slow_closes": float(os.environ["WS_SLOW_CLOSES"]),
        "ws_dropped_msgs": float(os.environ["WS_DROPPED_MSGS"]),
        "ws_send_queue_p99": float(os.environ["WS_QUEUE_P99"]),
        "ws_close_code": int(os.environ["CLOSE_CODE"]),
    },
    "logs": {
        "edge": os.environ["EDGE_LOG"],
        "ws_client": os.environ["WS_CLIENT_LOG"],
        "ws_events": os.environ["WS_EVENTS_LOG"],
    },
}

with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "ws_smoke_success=true"
echo "ws_slow_closes=${WS_SLOW_CLOSES}"
echo "ws_dropped_msgs=${WS_DROPPED_MSGS}"
echo "ws_send_queue_p99=${WS_QUEUE_P99}"
echo "ws_smoke_report=${REPORT_FILE}"
