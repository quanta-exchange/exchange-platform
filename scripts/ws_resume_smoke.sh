#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date +%s)"
EDGE_PORT="${EDGE_PORT:-$((27000 + RANDOM % 2000))}"
EDGE_URL="http://localhost:${EDGE_PORT}"
WS_URL="ws://localhost:${EDGE_PORT}/ws"
EDGE_LOG="/tmp/edge-gateway-ws-resume-${RUN_ID}.log"
CAPTURE_LOG="/tmp/ws-resume-capture-${RUN_ID}.log"
REPLAY_LOG="/tmp/ws-resume-replay-${RUN_ID}.log"
GAP_LOG="/tmp/ws-resume-gap-${RUN_ID}.log"
OUT_DIR="${OUT_DIR:-build/ws}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/ws-resume-smoke.json}"
CAPTURE_EVENTS_FILE="${OUT_DIR}/ws-resume-capture-${RUN_ID}.jsonl"
REPLAY_EVENTS_FILE="${OUT_DIR}/ws-resume-replay-${RUN_ID}.jsonl"
GAP_EVENTS_FILE="${OUT_DIR}/ws-resume-gap-${RUN_ID}.jsonl"
CAPTURE_COUNT="${CAPTURE_COUNT:-5}"
REPLAY_COUNT="${REPLAY_COUNT:-8}"
EVICT_COUNT="${EVICT_COUNT:-320}"
PARALLEL_POSTS="${PARALLEL_POSTS:-40}"
TRADE_INDEX=1

mkdir -p "${OUT_DIR}"
export EDGE_URL RUN_ID

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
require_cmd python3 "Install python3."

cleanup() {
  if [[ -n "${CAPTURE_PID:-}" ]] && kill -0 "${CAPTURE_PID}" >/dev/null 2>&1; then
    kill "${CAPTURE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "${EDGE_PID}" >/dev/null 2>&1; then
    kill "${EDGE_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

extract_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "${file}" | tail -n 1 | sed "s/^${key}=//"
}

metric_value() {
  local metrics="$1"
  local key="$2"
  echo "${metrics}" | awk -v metric="${key}" '$1 == metric {print $2; exit}'
}

flood_trades() {
  local count="$1"
  local start="${TRADE_INDEX}"
  local end=$((start + count - 1))
  TRADE_INDEX=$((end + 1))
  seq "${start}" "${end}" | xargs -I{} -P "${PARALLEL_POSTS}" bash -c '
    i="$1"
    curl -fsS -X POST "${EDGE_URL}/v1/smoke/trades" \
      -H "Content-Type: application/json" \
      -d "{\"tradeId\":\"ws-resume-'"${RUN_ID}"'-${i}\",\"symbol\":\"BTC-KRW\",\"price\":\"100\",\"qty\":\"1\"}" >/dev/null
  ' _ {}
}

cd "${ROOT_DIR}"

EDGE_ADDR=":${EDGE_PORT}" \
EDGE_DISABLE_DB="true" \
EDGE_DISABLE_CORE="true" \
EDGE_SEED_MARKET_DATA="false" \
EDGE_ENABLE_SMOKE_ROUTES="true" \
EDGE_ALLOW_INSECURE_NO_AUTH="true" \
EDGE_API_SECRETS="" \
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

go run ./scripts/ws_resume_client.go \
  -url "${WS_URL}" \
  -mode "capture" \
  -symbol "BTC-KRW" \
  -channel "trades" \
  -expect "trade" \
  -count "${CAPTURE_COUNT}" \
  -out "${CAPTURE_EVENTS_FILE}" \
  -timeout "25s" >"${CAPTURE_LOG}" 2>&1 &
CAPTURE_PID=$!

sleep 1
flood_trades "${CAPTURE_COUNT}"
wait "${CAPTURE_PID}"
unset CAPTURE_PID

CAPTURE_COLLECTED="$(extract_value ws_resume_collected "${CAPTURE_LOG}")"
CAPTURE_MIN_SEQ="$(extract_value ws_resume_min_seq "${CAPTURE_LOG}")"
CAPTURE_LAST_SEQ="$(extract_value ws_resume_last_seq "${CAPTURE_LOG}")"
if [[ -z "${CAPTURE_COLLECTED}" || -z "${CAPTURE_MIN_SEQ}" || -z "${CAPTURE_LAST_SEQ}" ]]; then
  echo "failed to parse capture output" >&2
  cat "${CAPTURE_LOG}" >&2 || true
  exit 1
fi
if (( CAPTURE_COLLECTED < CAPTURE_COUNT )); then
  echo "capture collected too few trades: ${CAPTURE_COLLECTED}" >&2
  exit 1
fi

flood_trades "${REPLAY_COUNT}"

go run ./scripts/ws_resume_client.go \
  -url "${WS_URL}" \
  -mode "resume" \
  -symbol "BTC-KRW" \
  -channel "trades" \
  -expect "trade" \
  -last-seq "${CAPTURE_LAST_SEQ}" \
  -count "${REPLAY_COUNT}" \
  -out "${REPLAY_EVENTS_FILE}" \
  -timeout "25s" >"${REPLAY_LOG}" 2>&1

REPLAY_COLLECTED="$(extract_value ws_resume_collected "${REPLAY_LOG}")"
REPLAY_MIN_SEQ="$(extract_value ws_resume_min_seq "${REPLAY_LOG}")"
REPLAY_LAST_SEQ="$(extract_value ws_resume_last_seq "${REPLAY_LOG}")"
REPLAY_FIRST_TYPE="$(extract_value ws_resume_first_type "${REPLAY_LOG}")"
if [[ -z "${REPLAY_COLLECTED}" || -z "${REPLAY_MIN_SEQ}" || -z "${REPLAY_LAST_SEQ}" || -z "${REPLAY_FIRST_TYPE}" ]]; then
  echo "failed to parse replay output" >&2
  cat "${REPLAY_LOG}" >&2 || true
  exit 1
fi
if (( REPLAY_COLLECTED < REPLAY_COUNT )); then
  echo "replay collected too few trades: ${REPLAY_COLLECTED}" >&2
  exit 1
fi
EXPECTED_REPLAY_MIN=$((CAPTURE_LAST_SEQ + 1))
if (( REPLAY_MIN_SEQ != EXPECTED_REPLAY_MIN )); then
  echo "resume replay sequence mismatch: expected min ${EXPECTED_REPLAY_MIN}, got ${REPLAY_MIN_SEQ}" >&2
  exit 1
fi
if [[ "${REPLAY_FIRST_TYPE}" != "TradeExecuted" ]]; then
  echo "expected replay first type TradeExecuted, got ${REPLAY_FIRST_TYPE}" >&2
  exit 1
fi

flood_trades "${EVICT_COUNT}"

go run ./scripts/ws_resume_client.go \
  -url "${WS_URL}" \
  -mode "resume" \
  -symbol "BTC-KRW" \
  -channel "trades" \
  -expect "any" \
  -last-seq "${CAPTURE_MIN_SEQ}" \
  -count "1" \
  -out "${GAP_EVENTS_FILE}" \
  -timeout "25s" >"${GAP_LOG}" 2>&1

GAP_FIRST_TYPE="$(extract_value ws_resume_first_type "${GAP_LOG}")"
GAP_SEQ="$(extract_value ws_resume_last_seq "${GAP_LOG}")"
if [[ -z "${GAP_FIRST_TYPE}" || -z "${GAP_SEQ}" ]]; then
  echo "failed to parse gap output" >&2
  cat "${GAP_LOG}" >&2 || true
  exit 1
fi
if [[ "${GAP_FIRST_TYPE}" != "Snapshot" && "${GAP_FIRST_TYPE}" != "Missed" ]]; then
  echo "expected gap recovery signal Snapshot|Missed, got ${GAP_FIRST_TYPE}" >&2
  exit 1
fi

METRICS="$(curl -fsS "${EDGE_URL}/metrics")"
WS_RESUME_GAPS="$(metric_value "${METRICS}" "ws_resume_gaps")"
if [[ -z "${WS_RESUME_GAPS}" ]]; then
  echo "missing ws_resume_gaps from /metrics output" >&2
  echo "${METRICS}" >&2
  exit 1
fi
if (( ${WS_RESUME_GAPS%.*} < 1 )); then
  echo "expected ws_resume_gaps >= 1, got ${WS_RESUME_GAPS}" >&2
  exit 1
fi

REPORT_FILE="${REPORT_FILE}" \
RUN_ID="${RUN_ID}" \
EDGE_URL="${EDGE_URL}" \
WS_URL="${WS_URL}" \
CAPTURE_COUNT="${CAPTURE_COUNT}" \
REPLAY_COUNT="${REPLAY_COUNT}" \
EVICT_COUNT="${EVICT_COUNT}" \
CAPTURE_MIN_SEQ="${CAPTURE_MIN_SEQ}" \
CAPTURE_LAST_SEQ="${CAPTURE_LAST_SEQ}" \
REPLAY_MIN_SEQ="${REPLAY_MIN_SEQ}" \
REPLAY_LAST_SEQ="${REPLAY_LAST_SEQ}" \
GAP_SEQ="${GAP_SEQ}" \
GAP_FIRST_TYPE="${GAP_FIRST_TYPE}" \
EDGE_LOG="${EDGE_LOG}" \
CAPTURE_LOG="${CAPTURE_LOG}" \
REPLAY_LOG="${REPLAY_LOG}" \
GAP_LOG="${GAP_LOG}" \
CAPTURE_EVENTS_FILE="${CAPTURE_EVENTS_FILE}" \
REPLAY_EVENTS_FILE="${REPLAY_EVENTS_FILE}" \
GAP_EVENTS_FILE="${GAP_EVENTS_FILE}" \
WS_RESUME_GAPS="${WS_RESUME_GAPS}" \
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
        "capture_count": int(os.environ["CAPTURE_COUNT"]),
        "replay_count": int(os.environ["REPLAY_COUNT"]),
        "evict_count": int(os.environ["EVICT_COUNT"]),
    },
    "replay": {
        "capture_min_seq": int(os.environ["CAPTURE_MIN_SEQ"]),
        "capture_last_seq": int(os.environ["CAPTURE_LAST_SEQ"]),
        "resume_min_seq": int(os.environ["REPLAY_MIN_SEQ"]),
        "resume_last_seq": int(os.environ["REPLAY_LAST_SEQ"]),
    },
    "gap_recovery": {
        "result_type": os.environ["GAP_FIRST_TYPE"],
        "snapshot_seq": int(os.environ["GAP_SEQ"]),
    },
    "metrics": {
        "ws_resume_gaps": float(os.environ["WS_RESUME_GAPS"]),
    },
    "logs": {
        "edge": os.environ["EDGE_LOG"],
        "capture": os.environ["CAPTURE_LOG"],
        "replay": os.environ["REPLAY_LOG"],
        "gap": os.environ["GAP_LOG"],
    },
    "events": {
        "capture": os.environ["CAPTURE_EVENTS_FILE"],
        "replay": os.environ["REPLAY_EVENTS_FILE"],
        "gap": os.environ["GAP_EVENTS_FILE"],
    },
}

with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "ws_resume_smoke_success=true"
echo "ws_resume_capture_last_seq=${CAPTURE_LAST_SEQ}"
echo "ws_resume_replay_last_seq=${REPLAY_LAST_SEQ}"
echo "ws_resume_gap_first_type=${GAP_FIRST_TYPE}"
echo "ws_resume_gaps=${WS_RESUME_GAPS}"
echo "ws_resume_smoke_report=${REPORT_FILE}"
