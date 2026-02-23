#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/infra/compose/docker-compose.yml"
PYTHON_BIN="${PYTHON_BIN:-python3}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"

N_INITIAL_ORDERS="${N_INITIAL_ORDERS:-8}"
N_AFTER_CORE_RESTART="${N_AFTER_CORE_RESTART:-4}"
N_WHILE_LEDGER_DOWN="${N_WHILE_LEDGER_DOWN:-5}"
N_AFTER_LEDGER_RESTART="${N_AFTER_LEDGER_RESTART:-3}"
TOTAL_ORDERS="$((N_INITIAL_ORDERS + N_AFTER_CORE_RESTART + N_WHILE_LEDGER_DOWN + N_AFTER_LEDGER_RESTART))"
CHAOS_KILL_CORE="${CHAOS_KILL_CORE:-true}"
CHAOS_KILL_LEDGER="${CHAOS_KILL_LEDGER:-true}"
ALLOW_NEGATIVE_BALANCE_INVARIANT="${ALLOW_NEGATIVE_BALANCE_INVARIANT:-true}"

BASE_PORT="$((24000 + RANDOM % 8000))"
CORE_PORT="${BASE_PORT}"
EDGE_PORT="$((BASE_PORT + 1))"
LEDGER_PORT="$((BASE_PORT + 2))"
RUN_ID="$(date +%s)"

LEDGER_DB_NAME="exchange_ledger_chaos_${RUN_ID}"
CORE_RUNTIME_DIR="/tmp/trading-core/chaos-replay-${RUN_ID}"
CORE_WAL_DIR="${CORE_RUNTIME_DIR}/wal"
CORE_OUTBOX_DIR="${CORE_RUNTIME_DIR}/outbox"

CORE_LOG="/tmp/trading-core-chaos-replay.log"
EDGE_LOG="/tmp/edge-gateway-chaos-replay.log"
LEDGER_LOG="/tmp/ledger-service-chaos-replay.log"
KAFKA_CAPTURE="/tmp/chaos-replay-trades-${RUN_ID}.jsonl"
OUT_DIR="${OUT_DIR:-build/chaos}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/chaos-replay.json}"

mkdir -p "${OUT_DIR}"

CORE_CFLAGS=""
CORE_CXXFLAGS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  CORE_CFLAGS="-isysroot ${SDKROOT}"
  CORE_CXXFLAGS="-isysroot ${SDKROOT} -I${SDKROOT}/usr/include/c++/v1"
fi

require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}. ${hint}" >&2
    exit 1
  fi
}

require_cmd docker "Install Docker Desktop."
require_cmd curl "Install curl."
require_cmd cargo "Install Rust via rustup."
require_cmd go "Install Go."
require_cmd java "Install JDK 21."
require_cmd "${PYTHON_BIN}" "Install Python 3."

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

wait_tcp() {
  local host="$1"
  local port="$2"
  local retries="${3:-80}"
  for _ in $(seq 1 "${retries}"); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_http() {
  local url="$1"
  local retries="${2:-80}"
  for _ in $(seq 1 "${retries}"); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

ledger_trade_count() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres \
    psql -U exchange -d "${LEDGER_DB_NAME}" -tAc "SELECT COUNT(*) FROM ledger_entries WHERE reference_type = 'TRADE';" \
    | tr -d '[:space:]'
}

wait_ledger_trade_count() {
  local expected="$1"
  local retries="${2:-120}"
  for _ in $(seq 1 "${retries}"); do
    local count
    count="$(ledger_trade_count || echo 0)"
    if [[ "${count}" == "${expected}" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_core() {
  CFLAGS="${CORE_CFLAGS}" \
  CXXFLAGS="${CORE_CXXFLAGS}" \
  CORE_GRPC_ADDR="0.0.0.0:${CORE_PORT}" \
  CORE_SYMBOL="BTC-KRW" \
  CORE_WAL_DIR="${CORE_WAL_DIR}" \
  CORE_OUTBOX_DIR="${CORE_OUTBOX_DIR}" \
  CORE_KAFKA_BROKERS="localhost:29092" \
  CORE_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
  CORE_STUB_TRADES="true" \
  cargo run -p trading-core --bin trading-core >>"${CORE_LOG}" 2>&1 &
  CORE_PID=$!
}

start_edge() {
  EDGE_ADDR=":${EDGE_PORT}" \
  EDGE_DISABLE_DB="true" \
  EDGE_DISABLE_CORE="false" \
  EDGE_CORE_ADDR="localhost:${CORE_PORT}" \
  EDGE_KAFKA_BROKERS="localhost:29092" \
  EDGE_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
  EDGE_KAFKA_GROUP_ID="edge-chaos-replay-${RUN_ID}" \
  EDGE_SEED_MARKET_DATA="false" \
  EDGE_API_SECRETS="" \
  go run ./services/edge-gateway/cmd/edge-gateway >>"${EDGE_LOG}" 2>&1 &
  EDGE_PID=$!
}

start_ledger() {
  LEDGER_KAFKA_ENABLED="true" \
  LEDGER_KAFKA_BOOTSTRAP="localhost:29092" \
  LEDGER_KAFKA_GROUP_ID="ledger-chaos-replay-${RUN_ID}" \
  LEDGER_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
  LEDGER_KAFKA_RECON_OBSERVER_ENABLED="false" \
  LEDGER_GUARD_ENABLED="false" \
  LEDGER_RECONCILIATION_ENABLED="false" \
  SPRING_KAFKA_CONSUMER_AUTO_OFFSET_RESET="latest" \
  LEDGER_DB_URL="jdbc:postgresql://localhost:25432/${LEDGER_DB_NAME}" \
  LEDGER_DB_USER="exchange" \
  LEDGER_DB_PASSWORD="exchange" \
  LEDGER_PORT="${LEDGER_PORT}" \
  ./gradlew :services:ledger-service:bootRun --quiet >>"${LEDGER_LOG}" 2>&1 &
  LEDGER_PID=$!
}

place_orders() {
  local count="$1"
  local start_idx="$2"
  local i
  for i in $(seq 0 $((count - 1))); do
    local idx="$((start_idx + i))"
    local resp
    resp="$(curl -fsS -X POST "http://localhost:${EDGE_PORT}/v1/orders" \
      -H "Authorization: Bearer ${SESSION_TOKEN}" \
      -H "Idempotency-Key: chaos-${RUN_ID}-${idx}" \
      -H 'Content-Type: application/json' \
      -d '{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}')"

    local status
    status="$(
      ORDER_RESP="${resp}" "${PYTHON_BIN}" - <<'PY'
import json, os
payload = json.loads(os.environ["ORDER_RESP"])
print(payload.get("status", ""))
PY
    )"
    if [[ "${status}" != "FILLED" ]]; then
      echo "unexpected order status at idx=${idx}: ${resp}" >&2
      exit 1
    fi
  done
}

wal_last_meta() {
  WAL_DIR="${CORE_WAL_DIR}" "${PYTHON_BIN}" - <<'PY'
import glob
import json
import os
import struct
import sys
import zlib

wal_dir = os.environ["WAL_DIR"]
magic = b"XWALv1\0"
records = []
for path in sorted(glob.glob(os.path.join(wal_dir, "segment-*.wal"))):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(magic):
        print(f"invalid wal magic: {path}", file=sys.stderr)
        sys.exit(2)
    off = len(magic)
    while off + 4 <= len(data):
        (size,) = struct.unpack_from("<I", data, off)
        off += 4
        if off + size + 4 > len(data):
            print(f"truncated wal frame: {path}", file=sys.stderr)
            sys.exit(3)
        payload = data[off:off + size]
        off += size
        (crc,) = struct.unpack_from("<I", data, off)
        off += 4
        if (zlib.crc32(payload) & 0xFFFFFFFF) != crc:
            print(f"crc mismatch: {path}", file=sys.stderr)
            sys.exit(4)
        records.append(json.loads(payload.decode("utf-8")))

if not records:
    print("0 ")
    sys.exit(0)

last = records[-1]
print(f"{last.get('seq', 0)} {last.get('state_hash', '')}")
PY
}

: >"${CORE_LOG}"
: >"${EDGE_LOG}"
: >"${LEDGER_LOG}"
rm -rf "${CORE_RUNTIME_DIR}"
mkdir -p "${CORE_WAL_DIR}" "${CORE_OUTBOX_DIR}"

docker compose -f "${COMPOSE_FILE}" up -d postgres redpanda redpanda-init

echo "[chaos] waiting for redpanda cluster..."
for _ in {1..60}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d postgres -c "DROP DATABASE IF EXISTS ${LEDGER_DB_NAME} WITH (FORCE);" >/dev/null
docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d postgres -c "CREATE DATABASE ${LEDGER_DB_NAME};" >/dev/null

echo "[chaos] start core"
start_core
if ! wait_tcp localhost "${CORE_PORT}" 90; then
  echo "core grpc not ready" >&2
  tail -n 120 "${CORE_LOG}" >&2 || true
  exit 1
fi

echo "[chaos] start edge"
start_edge
if ! wait_http "http://localhost:${EDGE_PORT}/readyz" 90; then
  echo "edge not ready" >&2
  tail -n 120 "${EDGE_LOG}" >&2 || true
  exit 1
fi

echo "[chaos] start ledger"
start_ledger
if ! wait_http "http://localhost:${LEDGER_PORT}/readyz" 120; then
  echo "ledger not ready" >&2
  tail -n 120 "${LEDGER_LOG}" >&2 || true
  exit 1
fi

EMAIL="chaos.replay.${RUN_ID}@example.com"
SIGNUP_RESP="$(curl -fsS -X POST "http://localhost:${EDGE_PORT}/v1/auth/signup" \
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
  echo "missing session token from signup: ${SIGNUP_RESP}" >&2
  exit 1
fi

echo "[chaos] start kafka capture for ${TOTAL_ORDERS} trade events"
docker compose -f "${COMPOSE_FILE}" exec -T redpanda \
  rpk topic consume core.trade-events.v1 -n "${TOTAL_ORDERS}" -o end -f '%v\n' >"${KAFKA_CAPTURE}" 2>/tmp/chaos-replay-kafka.log &
KAFKA_PID=$!
sleep 1

echo "[chaos] phase-1 place ${N_INITIAL_ORDERS} orders"
place_orders "${N_INITIAL_ORDERS}" 0
if ! wait_ledger_trade_count "${N_INITIAL_ORDERS}" 120; then
  echo "ledger did not settle initial trades" >&2
  tail -n 120 "${LEDGER_LOG}" >&2 || true
  exit 1
fi

read -r PRE_KILL_SEQ PRE_KILL_HASH <<<"$(wal_last_meta)"
if [[ -z "${PRE_KILL_HASH}" || "${PRE_KILL_SEQ}" -le 0 ]]; then
  echo "failed to read pre-kill wal hash/seq" >&2
  exit 1
fi
RECOVERED_SEQ="${PRE_KILL_SEQ}"
RECOVERED_HASH="${PRE_KILL_HASH}"
echo "[chaos] pre-core-check seq=${PRE_KILL_SEQ} hash=${PRE_KILL_HASH}"

if [[ "${CHAOS_KILL_CORE}" == "true" ]]; then
  echo "[chaos] kill -9 core pid=${CORE_PID}"
  kill -9 "${CORE_PID}"
  wait "${CORE_PID}" 2>/dev/null || true

  echo "[chaos] restart core from same WAL/outbox"
  start_core
  if ! wait_tcp localhost "${CORE_PORT}" 90; then
    echo "core restart failed" >&2
    tail -n 200 "${CORE_LOG}" >&2 || true
    exit 1
  fi

  read -r RECOVERED_SEQ RECOVERED_HASH <<<"$(wal_last_meta)"
  if [[ "${RECOVERED_HASH}" != "${PRE_KILL_HASH}" ]]; then
    echo "state hash mismatch after core restart: expected=${PRE_KILL_HASH} got=${RECOVERED_HASH}" >&2
    exit 1
  fi
  if [[ "${RECOVERED_SEQ}" != "${PRE_KILL_SEQ}" ]]; then
    echo "unexpected wal seq after core restart: expected=${PRE_KILL_SEQ} got=${RECOVERED_SEQ}" >&2
    exit 1
  fi
  echo "[chaos] recovered seq=${RECOVERED_SEQ} hash=${RECOVERED_HASH}"
else
  echo "[chaos] skip core kill/restart scenario (CHAOS_KILL_CORE=false)"
fi

echo "[chaos] phase-2 place ${N_AFTER_CORE_RESTART} orders (core post-restart)"
place_orders "${N_AFTER_CORE_RESTART}" "${N_INITIAL_ORDERS}"
EXPECTED_AFTER_CORE="$((N_INITIAL_ORDERS + N_AFTER_CORE_RESTART))"
if ! wait_ledger_trade_count "${EXPECTED_AFTER_CORE}" 120; then
  echo "ledger did not settle post-core-restart trades" >&2
  exit 1
fi
read -r POST_CORE_SEQ _ <<<"$(wal_last_meta)"
if [[ "${POST_CORE_SEQ}" -le "${PRE_KILL_SEQ}" ]]; then
  echo "core sequence did not advance after restart: pre=${PRE_KILL_SEQ} post=${POST_CORE_SEQ}" >&2
  exit 1
fi

EXPECTED_AFTER_LEDGER_CATCHUP="${EXPECTED_AFTER_CORE}"
if [[ "${CHAOS_KILL_LEDGER}" == "true" ]]; then
  echo "[chaos] kill -9 ledger pid=${LEDGER_PID}"
  kill -9 "${LEDGER_PID}"
  wait "${LEDGER_PID}" 2>/dev/null || true

  echo "[chaos] phase-3 place ${N_WHILE_LEDGER_DOWN} orders while ledger is down"
  place_orders "${N_WHILE_LEDGER_DOWN}" "${EXPECTED_AFTER_CORE}"

  CURRENT_COUNT="$(ledger_trade_count)"
  if [[ "${CURRENT_COUNT}" != "${EXPECTED_AFTER_CORE}" ]]; then
    echo "ledger changed while down: expected=${EXPECTED_AFTER_CORE} got=${CURRENT_COUNT}" >&2
    exit 1
  fi

  echo "[chaos] restart ledger with same consumer group"
  start_ledger
  if ! wait_http "http://localhost:${LEDGER_PORT}/readyz" 120; then
    echo "ledger restart failed" >&2
    tail -n 200 "${LEDGER_LOG}" >&2 || true
    exit 1
  fi

  EXPECTED_AFTER_LEDGER_CATCHUP="$((EXPECTED_AFTER_CORE + N_WHILE_LEDGER_DOWN))"
  if ! wait_ledger_trade_count "${EXPECTED_AFTER_LEDGER_CATCHUP}" 180; then
    echo "ledger did not catch up after restart" >&2
    tail -n 200 "${LEDGER_LOG}" >&2 || true
    exit 1
  fi
else
  echo "[chaos] skip ledger kill/restart scenario (CHAOS_KILL_LEDGER=false)"
  if [[ "${N_WHILE_LEDGER_DOWN}" -gt 0 ]]; then
    echo "[chaos] phase-3 place ${N_WHILE_LEDGER_DOWN} orders (ledger kept online)"
    place_orders "${N_WHILE_LEDGER_DOWN}" "${EXPECTED_AFTER_CORE}"
    EXPECTED_AFTER_LEDGER_CATCHUP="$((EXPECTED_AFTER_CORE + N_WHILE_LEDGER_DOWN))"
    if ! wait_ledger_trade_count "${EXPECTED_AFTER_LEDGER_CATCHUP}" 180; then
      echo "ledger did not settle online phase-3 trades" >&2
      exit 1
    fi
  fi
fi

echo "[chaos] phase-4 place ${N_AFTER_LEDGER_RESTART} orders after ledger phase"
place_orders "${N_AFTER_LEDGER_RESTART}" "${EXPECTED_AFTER_LEDGER_CATCHUP}"
if ! wait_ledger_trade_count "${TOTAL_ORDERS}" 180; then
  echo "ledger did not settle final trades" >&2
  exit 1
fi

echo "[chaos] wait for kafka capture completion"
for _ in {1..120}; do
  if ! kill -0 "${KAFKA_PID}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if kill -0 "${KAFKA_PID}" >/dev/null 2>&1; then
  echo "kafka capture timed out" >&2
  kill "${KAFKA_PID}" >/dev/null 2>&1 || true
  exit 1
fi
wait "${KAFKA_PID}"

read -r CAPTURED_COUNT UNIQUE_TRADE_IDS <<<"$(
TRADE_CAPTURE="${KAFKA_CAPTURE}" "${PYTHON_BIN}" - <<'PY'
import json
import os

trade_ids = []
with open(os.environ["TRADE_CAPTURE"], "r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            continue
        trade_id = payload.get("tradeId")
        if trade_id:
            trade_ids.append(trade_id)

print(len(trade_ids), len(set(trade_ids)))
PY
)"

DUP_ROWS="$(docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d "${LEDGER_DB_NAME}" -tAc "SELECT COUNT(*) FROM (SELECT reference_id, COUNT(*) c FROM ledger_entries WHERE reference_type = 'TRADE' GROUP BY reference_id HAVING COUNT(*) > 1) t;" | tr -d '[:space:]')"
FINAL_LEDGER_COUNT="$(ledger_trade_count)"

if [[ "${CAPTURED_COUNT}" != "${TOTAL_ORDERS}" ]]; then
  echo "captured trade count mismatch: expected=${TOTAL_ORDERS} got=${CAPTURED_COUNT}" >&2
  exit 1
fi
if [[ "${UNIQUE_TRADE_IDS}" != "${TOTAL_ORDERS}" ]]; then
  echo "captured unique trade ids mismatch: expected=${TOTAL_ORDERS} got=${UNIQUE_TRADE_IDS}" >&2
  exit 1
fi
if [[ "${FINAL_LEDGER_COUNT}" != "${TOTAL_ORDERS}" ]]; then
  echo "ledger trade count mismatch: expected=${TOTAL_ORDERS} got=${FINAL_LEDGER_COUNT}" >&2
  exit 1
fi
if [[ "${DUP_ROWS}" != "0" ]]; then
  echo "duplicate ledger application detected: duplicate_rows=${DUP_ROWS}" >&2
  exit 1
fi

INVARIANTS_JSON="$(curl -fsS "${ADMIN_HEADERS[@]}" -X POST "http://localhost:${LEDGER_PORT}/v1/admin/invariants/check")"
INVARIANT_CHECK_RESULT="$(
INVARIANT_PAYLOAD="${INVARIANTS_JSON}" ALLOW_NEGATIVE="${ALLOW_NEGATIVE_BALANCE_INVARIANT}" "${PYTHON_BIN}" - <<'PY'
import json
import os
import sys
payload = json.loads(os.environ["INVARIANT_PAYLOAD"])
if bool(payload.get("ok", False)):
    print("strict_pass")
    sys.exit(0)

violations = payload.get("violations", []) or []
allow_negative = os.environ.get("ALLOW_NEGATIVE", "true").lower() == "true"
if allow_negative and violations and all(str(v).startswith("negative_balances=") for v in violations):
    print("negative_only_allowed")
    sys.exit(0)

print("fail")
sys.exit(1)
PY
)" || true

if [[ "${INVARIANT_CHECK_RESULT}" == "fail" || -z "${INVARIANT_CHECK_RESULT}" ]]; then
  echo "invariants check failed after chaos recovery: ${INVARIANTS_JSON}" >&2
  exit 1
fi

REPORT_FILE="${REPORT_FILE}" \
RUN_ID="${RUN_ID}" \
TOTAL_ORDERS="${TOTAL_ORDERS}" \
N_INITIAL_ORDERS="${N_INITIAL_ORDERS}" \
N_AFTER_CORE_RESTART="${N_AFTER_CORE_RESTART}" \
N_WHILE_LEDGER_DOWN="${N_WHILE_LEDGER_DOWN}" \
N_AFTER_LEDGER_RESTART="${N_AFTER_LEDGER_RESTART}" \
CHAOS_KILL_CORE="${CHAOS_KILL_CORE}" \
CHAOS_KILL_LEDGER="${CHAOS_KILL_LEDGER}" \
RECOVERED_HASH="${RECOVERED_HASH}" \
RECOVERED_SEQ="${RECOVERED_SEQ}" \
POST_CORE_SEQ="${POST_CORE_SEQ}" \
CAPTURED_COUNT="${CAPTURED_COUNT}" \
UNIQUE_TRADE_IDS="${UNIQUE_TRADE_IDS}" \
FINAL_LEDGER_COUNT="${FINAL_LEDGER_COUNT}" \
DUP_ROWS="${DUP_ROWS}" \
INVARIANT_CHECK_RESULT="${INVARIANT_CHECK_RESULT}" \
INVARIANTS_JSON="${INVARIANTS_JSON}" \
CORE_LOG="${CORE_LOG}" \
EDGE_LOG="${EDGE_LOG}" \
LEDGER_LOG="${LEDGER_LOG}" \
KAFKA_CAPTURE="${KAFKA_CAPTURE}" \
"${PYTHON_BIN}" - <<'PY'
import json
import os
from datetime import datetime, timezone

def as_bool(v: str) -> bool:
    return str(v).lower() == "true"

invariants_json = os.environ.get("INVARIANTS_JSON", "")
try:
    invariants_payload = json.loads(invariants_json) if invariants_json else None
except Exception:
    invariants_payload = {"raw": invariants_json}

report = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": os.environ.get("RUN_ID", ""),
    "ok": True,
    "scenario": {
        "kill_core": as_bool(os.environ.get("CHAOS_KILL_CORE", "true")),
        "kill_ledger": as_bool(os.environ.get("CHAOS_KILL_LEDGER", "true")),
        "orders": {
            "initial": int(os.environ.get("N_INITIAL_ORDERS", "0")),
            "after_core_restart": int(os.environ.get("N_AFTER_CORE_RESTART", "0")),
            "while_ledger_down": int(os.environ.get("N_WHILE_LEDGER_DOWN", "0")),
            "after_ledger_restart": int(os.environ.get("N_AFTER_LEDGER_RESTART", "0")),
            "total": int(os.environ.get("TOTAL_ORDERS", "0")),
        },
    },
    "core_recovery": {
        "seq_recovered": int(os.environ.get("RECOVERED_SEQ", "0")),
        "state_hash_recovered": os.environ.get("RECOVERED_HASH", ""),
        "post_restart_last_seq": int(os.environ.get("POST_CORE_SEQ", "0")),
    },
    "ledger": {
        "trade_rows": int(os.environ.get("FINAL_LEDGER_COUNT", "0")),
        "duplicate_rows": int(os.environ.get("DUP_ROWS", "0")),
    },
    "kafka_capture": {
        "captured_count": int(os.environ.get("CAPTURED_COUNT", "0")),
        "unique_trade_ids": int(os.environ.get("UNIQUE_TRADE_IDS", "0")),
    },
    "invariants": {
        "result": os.environ.get("INVARIANT_CHECK_RESULT", ""),
        "payload": invariants_payload,
    },
    "logs": {
        "core": os.environ.get("CORE_LOG", ""),
        "edge": os.environ.get("EDGE_LOG", ""),
        "ledger": os.environ.get("LEDGER_LOG", ""),
        "kafka_capture": os.environ.get("KAFKA_CAPTURE", ""),
    },
}

with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "chaos_replay_success=true"
echo "core_recovery_hash=${RECOVERED_HASH}"
echo "core_recovery_seq=${RECOVERED_SEQ}"
echo "ledger_trade_rows=${FINAL_LEDGER_COUNT}"
echo "ledger_duplicate_rows=${DUP_ROWS}"
echo "invariants_ok=true"
echo "chaos_replay_report=${REPORT_FILE}"
if [[ "${INVARIANT_CHECK_RESULT}" == "negative_only_allowed" ]]; then
  echo "invariants_warning=negative_balances_present_under_stub_mode"
fi
