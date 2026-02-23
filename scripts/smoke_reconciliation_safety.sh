#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/infra/compose/docker-compose.yml"

CORE_LOG="/tmp/trading-core-reconciliation-smoke.log"
EDGE_LOG="/tmp/edge-gateway-reconciliation-smoke.log"
LEDGER_LOG="/tmp/ledger-service-reconciliation-smoke.log"
RUN_ID="$(date -u +%s)"
DB_NAME="exchange_reconciliation_smoke"
BASE_PORT="$((20000 + RANDOM % 10000))"
CORE_PORT="${BASE_PORT}"
EDGE_PORT="$((BASE_PORT + 1))"
LEDGER_PORT="$((BASE_PORT + 2))"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
CORE_RUNTIME_DIR="/tmp/trading-core-reconciliation-smoke-${RUN_ID}"
CORE_WAL_DIR="${CORE_RUNTIME_DIR}/wal"
CORE_OUTBOX_DIR="${CORE_RUNTIME_DIR}/outbox"
OUT_DIR="${OUT_DIR:-build/reconciliation}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/smoke-reconciliation-safety.json}"
LAG_THRESHOLD="${LEDGER_RECONCILIATION_LAG_THRESHOLD:-2}"

BREACH_CONFIRMED="false"
CANCEL_ONLY_REJECTED="false"
RECOVERY_CONFIRMED="false"
LATCH_RELEASED="false"
POST_RELEASE_ACCEPTED="false"
FAIL_REASON=""
BREACH_STATUS_JSON=""
RECOVERY_STATUS_JSON=""
LATCH_RELEASE_JSON=""

mkdir -p "${OUT_DIR}"

CORE_CFLAGS=""
CORE_CXXFLAGS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  CORE_CFLAGS="-isysroot ${SDKROOT}"
  CORE_CXXFLAGS="-isysroot ${SDKROOT} -I${SDKROOT}/usr/include/c++/v1"
fi

cleanup() {
  if [[ -n "${CORE_PID:-}" ]] && kill -0 "${CORE_PID}" 2>/dev/null; then
    kill "${CORE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "${EDGE_PID}" 2>/dev/null; then
    kill "${EDGE_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${LEDGER_PID:-}" ]] && kill -0 "${LEDGER_PID}" 2>/dev/null; then
    kill "${LEDGER_PID}" >/dev/null 2>&1 || true
  fi
}

write_report() {
  local exit_code="$1"
  REPORT_EXIT_CODE="${exit_code}" \
  RUN_ID="${RUN_ID}" \
  FAIL_REASON="${FAIL_REASON}" \
  LAG_THRESHOLD="${LAG_THRESHOLD}" \
  CORE_PORT="${CORE_PORT}" \
  EDGE_PORT="${EDGE_PORT}" \
  LEDGER_PORT="${LEDGER_PORT}" \
  BREACH_CONFIRMED="${BREACH_CONFIRMED}" \
  CANCEL_ONLY_REJECTED="${CANCEL_ONLY_REJECTED}" \
  RECOVERY_CONFIRMED="${RECOVERY_CONFIRMED}" \
  LATCH_RELEASED="${LATCH_RELEASED}" \
  POST_RELEASE_ACCEPTED="${POST_RELEASE_ACCEPTED}" \
  BREACH_STATUS_JSON="${BREACH_STATUS_JSON}" \
  RECOVERY_STATUS_JSON="${RECOVERY_STATUS_JSON}" \
  LATCH_RELEASE_JSON="${LATCH_RELEASE_JSON}" \
  CORE_LOG="${CORE_LOG}" \
  EDGE_LOG="${EDGE_LOG}" \
  LEDGER_LOG="${LEDGER_LOG}" \
  REPORT_FILE="${REPORT_FILE}" \
  "${PYTHON_BIN:-python3}" - <<'PY'
import json
import os
from datetime import datetime, timezone

def as_bool(value: str) -> bool:
    return str(value).lower() == "true"

def parse_json(value: str):
    if not value:
        return None
    try:
        return json.loads(value)
    except Exception:
        return {"raw": value}

exit_code = int(os.environ.get("REPORT_EXIT_CODE", "1"))
ok = exit_code == 0
report = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": os.environ.get("RUN_ID", ""),
    "ok": ok,
    "fail_reason": "" if ok else os.environ.get("FAIL_REASON", "script_failed"),
    "lag_threshold": int(os.environ.get("LAG_THRESHOLD", "2")),
    "ports": {
        "core": int(os.environ.get("CORE_PORT", "0")),
        "edge": int(os.environ.get("EDGE_PORT", "0")),
        "ledger": int(os.environ.get("LEDGER_PORT", "0")),
    },
    "checks": {
        "breach_confirmed": as_bool(os.environ.get("BREACH_CONFIRMED", "false")),
        "cancel_only_rejected": as_bool(os.environ.get("CANCEL_ONLY_REJECTED", "false")),
        "recovery_confirmed": as_bool(os.environ.get("RECOVERY_CONFIRMED", "false")),
        "latch_released": as_bool(os.environ.get("LATCH_RELEASED", "false")),
        "post_release_accepted": as_bool(os.environ.get("POST_RELEASE_ACCEPTED", "false")),
    },
    "status_samples": {
        "breach": parse_json(os.environ.get("BREACH_STATUS_JSON", "")),
        "recovery": parse_json(os.environ.get("RECOVERY_STATUS_JSON", "")),
    },
    "latch_release_response": parse_json(os.environ.get("LATCH_RELEASE_JSON", "")),
    "logs": {
        "core": os.environ.get("CORE_LOG", ""),
        "edge": os.environ.get("EDGE_LOG", ""),
        "ledger": os.environ.get("LEDGER_LOG", ""),
    },
}

report_file = os.environ.get("REPORT_FILE")
if report_file:
    with open(report_file, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")
PY
}

on_exit() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 && -z "${FAIL_REASON}" ]]; then
    FAIL_REASON="script_failed"
  fi
  write_report "${exit_code}"
  cleanup
}
trap on_exit EXIT

cd "${ROOT_DIR}"

docker compose -f "${COMPOSE_FILE}" up -d postgres redpanda redpanda-init redis clickhouse minio minio-init otel-collector prometheus

docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME} WITH (FORCE);" >/dev/null
docker compose -f "${COMPOSE_FILE}" exec -T postgres \
  psql -U exchange -d postgres -c "CREATE DATABASE ${DB_NAME};" >/dev/null

echo "Waiting for Redpanda..."
for _ in {1..30}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "Starting trading-core..."
rm -rf "${CORE_RUNTIME_DIR}"
mkdir -p "${CORE_WAL_DIR}" "${CORE_OUTBOX_DIR}"
CFLAGS="${CORE_CFLAGS}" \
CXXFLAGS="${CORE_CXXFLAGS}" \
CORE_GRPC_ADDR="0.0.0.0:${CORE_PORT}" \
CORE_WAL_DIR="${CORE_WAL_DIR}" \
CORE_OUTBOX_DIR="${CORE_OUTBOX_DIR}" \
CORE_KAFKA_BROKERS="localhost:29092" \
CORE_KAFKA_TRADE_TOPIC="core.trade-events.v1" \
CORE_STUB_TRADES="true" \
cargo run -p trading-core --bin trading-core >"${CORE_LOG}" 2>&1 &
CORE_PID=$!

echo "Starting ledger-service..."
LEDGER_KAFKA_ENABLED="true" \
LEDGER_KAFKA_BOOTSTRAP="localhost:29092" \
LEDGER_KAFKA_GROUP_ID="ledger-settlement-recon-smoke-${RUN_ID}" \
LEDGER_KAFKA_RECON_GROUP_ID="ledger-recon-observer-smoke-${RUN_ID}" \
SPRING_KAFKA_CONSUMER_AUTO_OFFSET_RESET="latest" \
LEDGER_DB_URL="jdbc:postgresql://localhost:25432/${DB_NAME}" \
LEDGER_DB_USER="exchange" \
LEDGER_DB_PASSWORD="exchange" \
LEDGER_PORT="${LEDGER_PORT}" \
LEDGER_GUARD_ENABLED="false" \
LEDGER_RECONCILIATION_ENABLED="true" \
LEDGER_RECONCILIATION_INTERVAL_MS="1000" \
LEDGER_RECONCILIATION_LAG_THRESHOLD="${LAG_THRESHOLD}" \
LEDGER_RECONCILIATION_SAFETY_MODE="CANCEL_ONLY" \
LEDGER_RECONCILIATION_AUTO_SWITCH="true" \
LEDGER_RECONCILIATION_LATCH_ALLOW_NEGATIVE="true" \
LEDGER_RECONCILIATION_CORE_GRPC_ADDR="localhost:${CORE_PORT}" \
./gradlew :services:ledger-service:bootRun --quiet >"${LEDGER_LOG}" 2>&1 &
LEDGER_PID=$!

echo "Waiting for trading-core gRPC..."
for _ in {1..60}; do
  if (echo > /dev/tcp/localhost/"${CORE_PORT}") >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! (echo > /dev/tcp/localhost/"${CORE_PORT}") >/dev/null 2>&1; then
  echo "trading-core readiness failed"
  cat "${CORE_LOG}"
  FAIL_REASON="core_not_ready"
  exit 1
fi

echo "Waiting for ledger-service..."
for _ in {1..60}; do
  if curl -fsS "http://localhost:${LEDGER_PORT}/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! curl -fsS "http://localhost:${LEDGER_PORT}/readyz" >/dev/null 2>&1; then
  echo "ledger-service readiness failed"
  cat "${LEDGER_LOG}"
  FAIL_REASON="ledger_not_ready"
  exit 1
fi

echo "Starting edge-gateway..."
EDGE_ADDR=":${EDGE_PORT}" \
EDGE_DB_DSN="postgres://exchange:exchange@localhost:25432/${DB_NAME}?sslmode=disable" \
EDGE_CORE_ADDR="localhost:${CORE_PORT}" \
EDGE_API_SECRETS="" \
go run ./services/edge-gateway/cmd/edge-gateway >"${EDGE_LOG}" 2>&1 &
EDGE_PID=$!

echo "Waiting for edge-gateway..."
for _ in {1..60}; do
  if curl -fsS "http://localhost:${EDGE_PORT}/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! curl -fsS "http://localhost:${EDGE_PORT}/readyz" >/dev/null 2>&1; then
  echo "edge-gateway readiness failed"
  cat "${EDGE_LOG}"
  FAIL_REASON="edge_not_ready"
  exit 1
fi

ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

USER_EMAIL="recon-smoke-${RUN_ID}@example.com"
SIGNUP_RESP="$(curl -fsS -X POST "http://localhost:${EDGE_PORT}/v1/auth/signup" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"${USER_EMAIL}\",\"password\":\"password123\"}")"

SESSION_TOKEN="$(SIGNUP_JSON="${SIGNUP_RESP}" python3 - <<'PY'
import json
import os
resp = json.loads(os.environ["SIGNUP_JSON"])
token = resp.get("sessionToken", "")
if not token:
    raise SystemExit(1)
print(token)
PY
)"

place_order() {
  local idem_key="$1"
  curl -fsS -X POST "http://localhost:${EDGE_PORT}/v1/orders" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${SESSION_TOKEN}" \
    -H "Idempotency-Key: ${idem_key}" \
    -d '{"symbol":"BTC-KRW","side":"BUY","type":"LIMIT","price":"100","qty":"1","timeInForce":"GTC"}'
}

BASELINE_ORDER="$(place_order "recon-base-${RUN_ID}")"
echo "baseline_order=${BASELINE_ORDER}"
sleep 2

PAUSE_RESP="$(curl -fsS "${ADMIN_HEADERS[@]}" -X POST "http://localhost:${LEDGER_PORT}/v1/admin/consumers/settlement/pause")"
echo "pause_consumer=${PAUSE_RESP}"
if ! PAUSE_JSON="${PAUSE_RESP}" python3 - <<'PY'
import json
import os
import sys
payload = json.loads(os.environ["PAUSE_JSON"])
container_paused = payload.get("containerPaused") is True
fallback_gate_paused = payload.get("available") is False and payload.get("gatePaused") is True
if container_paused or fallback_gate_paused:
    sys.exit(0)
sys.exit(1)
PY
then
  echo "settlement consumer pause was not fully applied"
  FAIL_REASON="settlement_pause_failed"
  exit 1
fi

for i in {1..8}; do
  order_resp="$(place_order "recon-lag-${RUN_ID}-${i}")"
  echo "lag_order_${i}=${order_resp}"
done

for _ in {1..45}; do
  STATUS_JSON="$(curl -fsS "${ADMIN_HEADERS[@]}" "http://localhost:${LEDGER_PORT}/v1/admin/reconciliation/status?historyLimit=30")"
  if LAG_THRESHOLD="${LAG_THRESHOLD}" STATUS_JSON="${STATUS_JSON}" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["STATUS_JSON"])
status = next((s for s in data.get("statuses", []) if s.get("symbol") == "BTC-KRW"), None)
if status is None:
    sys.exit(1)
lag = int(status.get("lag", 0))
breach_active = bool(status.get("breachActive", False))
history = [h for h in data.get("history", []) if h.get("symbol") == "BTC-KRW"]
safety_triggered = any(bool(h.get("safetyActionTaken", False)) for h in history)
if lag > int(os.environ["LAG_THRESHOLD"]) and breach_active and safety_triggered:
    print(f"lag={lag} breachActive={breach_active} safetyTriggered={safety_triggered}")
    sys.exit(0)
sys.exit(1)
PY
  then
    BREACH_CONFIRMED="true"
    BREACH_STATUS_JSON="${STATUS_JSON}"
    echo "reconciliation_status=${STATUS_JSON}"
    break
  fi
  sleep 1
done

if [[ "${BREACH_CONFIRMED}" != "true" ]]; then
  echo "reconciliation breach or safety trigger not observed in time"
  echo "--- ledger log ---"
  tail -n 120 "${LEDGER_LOG}" || true
  FAIL_REASON="reconciliation_breach_not_observed"
  exit 1
fi

REJECT_ORDER="$(place_order "recon-reject-${RUN_ID}")"
echo "post_safety_order=${REJECT_ORDER}"

if ! ORDER_JSON="${REJECT_ORDER}" python3 - <<'PY'
import json
import os
import sys
resp = json.loads(os.environ["ORDER_JSON"])
if resp.get("status") == "REJECTED" and resp.get("rejectCode") == "CANCEL_ONLY":
    sys.exit(0)
sys.exit(1)
PY
then
  echo "expected CANCEL_ONLY rejection after safety mode trigger"
  FAIL_REASON="cancel_only_rejection_missing"
  exit 1
fi
CANCEL_ONLY_REJECTED="true"

RESUME_RESP="$(curl -fsS "${ADMIN_HEADERS[@]}" -X POST "http://localhost:${LEDGER_PORT}/v1/admin/consumers/settlement/resume")"
echo "resume_consumer=${RESUME_RESP}"
if ! RESUME_JSON="${RESUME_RESP}" python3 - <<'PY'
import json
import os
import sys
payload = json.loads(os.environ["RESUME_JSON"])
gate_resumed = payload.get("gatePaused") is False
container_resumed = payload.get("available") is False or payload.get("containerPaused") is False
if gate_resumed and container_resumed:
    sys.exit(0)
sys.exit(1)
PY
then
  echo "settlement consumer resume was not fully applied"
  FAIL_REASON="settlement_resume_failed"
  exit 1
fi

for _ in {1..60}; do
  STATUS_JSON="$(curl -fsS "${ADMIN_HEADERS[@]}" "http://localhost:${LEDGER_PORT}/v1/admin/reconciliation/status?historyLimit=30")"
  if LAG_THRESHOLD="${LAG_THRESHOLD}" STATUS_JSON="${STATUS_JSON}" python3 - <<'PY'
import json
import os
import sys
data = json.loads(os.environ["STATUS_JSON"])
status = next((s for s in data.get("statuses", []) if s.get("symbol") == "BTC-KRW"), None)
if status is None:
    sys.exit(1)
lag = int(status.get("lag", 0))
if lag <= int(os.environ["LAG_THRESHOLD"]) and not bool(status.get("mismatch", False)) and not bool(status.get("thresholdBreached", False)):
    sys.exit(0)
sys.exit(1)
PY
  then
    RECOVERY_CONFIRMED="true"
    RECOVERY_STATUS_JSON="${STATUS_JSON}"
    break
  fi
  sleep 1
done

if [[ "${RECOVERY_CONFIRMED}" != "true" ]]; then
  echo "reconciliation recovery not observed in time"
  tail -n 120 "${LEDGER_LOG}" || true
  FAIL_REASON="reconciliation_recovery_not_observed"
  exit 1
fi

LATCH_RELEASE_RESP="$(curl -fsS "${ADMIN_HEADERS[@]}" -X POST "http://localhost:${LEDGER_PORT}/v1/admin/reconciliation/latch/BTC-KRW/release" \
  -H 'Content-Type: application/json' \
  -d '{"approvedBy":"smoke-ops","reason":"smoke_verified","restoreSymbolMode":true}')"
echo "latch_release=${LATCH_RELEASE_RESP}"
LATCH_RELEASE_JSON="${LATCH_RELEASE_RESP}"
if ! RELEASE_JSON="${LATCH_RELEASE_RESP}" python3 - <<'PY'
import json
import os
import sys
resp = json.loads(os.environ["RELEASE_JSON"])
if bool(resp.get("released", False)) and bool(resp.get("modeRestored", False)):
    sys.exit(0)
sys.exit(1)
PY
then
  echo "expected successful latch release with mode restore"
  FAIL_REASON="latch_release_failed"
  exit 1
fi
LATCH_RELEASED="true"

POST_RELEASE_ORDER="$(place_order "recon-post-release-${RUN_ID}")"
echo "post_release_order=${POST_RELEASE_ORDER}"
if ! ORDER_JSON="${POST_RELEASE_ORDER}" python3 - <<'PY'
import json
import os
import sys
resp = json.loads(os.environ["ORDER_JSON"])
if resp.get("status") == "REJECTED" and resp.get("rejectCode") == "CANCEL_ONLY":
    sys.exit(1)
sys.exit(0)
PY
then
  echo "order still rejected by CANCEL_ONLY after latch release"
  FAIL_REASON="post_release_still_cancel_only"
  exit 1
fi
POST_RELEASE_ACCEPTED="true"

echo "smoke_reconciliation_safety_success=true"
echo "smoke_reconciliation_report=${REPORT_FILE}"
