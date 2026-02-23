#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT_DIR}/infra/compose/docker-compose.yml}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/chaos}"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/network-partition-${TS_ID}.json}"
LATEST_FILE="${LATEST_FILE:-${OUT_DIR}/network-partition-latest.json}"
TOPIC="${TOPIC:-chaos.redpanda.network.partition.v1}"
PARTITION_SECONDS="${PARTITION_SECONDS:-5}"
ISOLATION_METHOD="${ISOLATION_METHOD:-auto}" # auto|pause|network-disconnect
LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
CHECK_INVARIANTS="${CHECK_INVARIANTS:-auto}" # off|auto|require
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${OUT_DIR}"

REDPANDA_CONTAINER_ID=""
REDPANDA_NETWORK=""
DISCONNECTED=false
PAUSED=false
STOPPED=false
APPLIED_METHOD=""

require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}. ${hint}" >&2
    exit 1
  fi
}

tcp_probe() {
  local host="$1"
  local port="$2"
  if "${PYTHON_BIN}" - "${host}" "${port}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=1.5):
        pass
except OSError:
    raise SystemExit(1)
raise SystemExit(0)
PY
  then
    return 0
  fi
  return 1
}

cleanup() {
  if [[ -n "${REDPANDA_CONTAINER_ID}" ]]; then
    if [[ "${PAUSED}" == "true" ]]; then
      docker unpause "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1 || true
      PAUSED=false
    fi
    if [[ "${DISCONNECTED}" == "true" && -n "${REDPANDA_NETWORK}" ]]; then
      docker network connect --alias redpanda "${REDPANDA_NETWORK}" "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1 || true
      DISCONNECTED=false
    fi
    if [[ "${STOPPED}" == "true" ]]; then
      docker start "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1 || true
      STOPPED=false
    fi
  fi
}
trap cleanup EXIT

wait_cluster_ready() {
  local retries="${1:-90}"
  for _ in $(seq 1 "${retries}"); do
    if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_tcp_state() {
  local expected="$1"
  local retries="${2:-30}"
  for _ in $(seq 1 "${retries}"); do
    if tcp_probe "localhost" "29092"; then
      if [[ "${expected}" == "up" ]]; then
        return 0
      fi
    else
      if [[ "${expected}" == "down" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

topic_total_high_watermark() {
  docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic describe "${TOPIC}" -p \
    | awk 'NR > 1 {sum += $6} END {print sum + 0}'
}

require_cmd docker "Install Docker Desktop."
require_cmd curl "Install curl."
require_cmd "${PYTHON_BIN}" "Install Python 3."

docker compose -f "${COMPOSE_FILE}" up -d redpanda redpanda-init
wait_cluster_ready 90

REDPANDA_CONTAINER_ID="$(docker compose -f "${COMPOSE_FILE}" ps -q redpanda | head -n 1)"
if [[ -z "${REDPANDA_CONTAINER_ID}" ]]; then
  echo "failed to resolve redpanda container id" >&2
  exit 1
fi
REDPANDA_NETWORK="$(
  docker inspect "${REDPANDA_CONTAINER_ID}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s\n" $k}}{{end}}' \
    | head -n 1 \
    | tr -d '[:space:]'
)"
if [[ -z "${REDPANDA_NETWORK}" ]]; then
  echo "failed to resolve redpanda network name" >&2
  exit 1
fi

docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic create "${TOPIC}" -p 3 -r 1 >/dev/null 2>&1 || true
printf '{"msg":"before-partition"}\n' | docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic produce "${TOPIC}" >/dev/null

if ! wait_tcp_state up 10; then
  echo "broker endpoint localhost:29092 is not reachable before partition injection" >&2
  exit 1
fi
BEFORE_REACHABLE=true

inject_disconnect() {
  if docker network disconnect "${REDPANDA_NETWORK}" "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1; then
    DISCONNECTED=true
    return 0
  fi
  return 1
}

inject_pause() {
  if docker pause "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1; then
    PAUSED=true
    return 0
  fi
  return 1
}

inject_stop() {
  if docker stop -t 1 "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1; then
    STOPPED=true
    PAUSED=false
    return 0
  fi
  return 1
}

case "${ISOLATION_METHOD}" in
  auto|AUTO)
    if inject_pause; then
      APPLIED_METHOD="pause"
    else
      echo "failed to apply any isolation method (pause/stop)" >&2
      exit 1
    fi
    ;;
  network-disconnect|NETWORK-DISCONNECT)
    if ! inject_disconnect; then
      echo "failed to disconnect redpanda container from network ${REDPANDA_NETWORK}" >&2
      exit 1
    fi
    APPLIED_METHOD="network-disconnect"
    ;;
  pause|PAUSE)
    if ! inject_pause; then
      echo "failed to pause redpanda container" >&2
      exit 1
    fi
    APPLIED_METHOD="pause"
    ;;
  *)
    echo "invalid ISOLATION_METHOD=${ISOLATION_METHOD} (expected auto|network-disconnect|pause)" >&2
    exit 1
    ;;
esac

sleep "${PARTITION_SECONDS}"

if wait_tcp_state down 6; then
  DURING_REACHABLE=false
else
  DURING_REACHABLE=true
  if [[ "${ISOLATION_METHOD}" == "auto" || "${ISOLATION_METHOD}" == "AUTO" ]]; then
    if [[ "${PAUSED}" != "true" ]] && inject_pause; then
      APPLIED_METHOD="${APPLIED_METHOD}+pause-fallback"
      sleep 2
      if wait_tcp_state down 6; then
        DURING_REACHABLE=false
      fi
    fi
    if [[ "${DURING_REACHABLE}" == "true" ]] && [[ "${STOPPED}" != "true" ]] && inject_stop; then
      APPLIED_METHOD="${APPLIED_METHOD}+stop-fallback"
      sleep 2
      if wait_tcp_state down 6; then
        DURING_REACHABLE=false
      fi
    fi
  fi
fi

if [[ "${DURING_REACHABLE}" == "true" ]]; then
  echo "partition drill failed: broker endpoint remained reachable during isolation" >&2
  exit 1
fi

if [[ "${PAUSED}" == "true" ]]; then
  docker unpause "${REDPANDA_CONTAINER_ID}" >/dev/null 2>&1 || true
  PAUSED=false
fi
if [[ "${DISCONNECTED}" == "true" ]]; then
  docker network connect --alias redpanda "${REDPANDA_NETWORK}" "${REDPANDA_CONTAINER_ID}" >/dev/null
  DISCONNECTED=false
fi
if [[ "${STOPPED}" == "true" ]]; then
  docker start "${REDPANDA_CONTAINER_ID}" >/dev/null
  STOPPED=false
fi

wait_cluster_ready 90
if ! wait_tcp_state up 30; then
  echo "broker endpoint localhost:29092 did not recover after isolation" >&2
  exit 1
fi
AFTER_REACHABLE=true

HWM_BEFORE="$(topic_total_high_watermark)"
printf '{"msg":"after-partition"}\n' | docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic produce "${TOPIC}" >/dev/null
sleep 1
HWM_AFTER="$(topic_total_high_watermark)"
PRODUCE_CONSUME_OK=false
if [[ "${HWM_AFTER}" =~ ^[0-9]+$ ]] && [[ "${HWM_BEFORE}" =~ ^[0-9]+$ ]] && (( HWM_AFTER > HWM_BEFORE )); then
  PRODUCE_CONSUME_OK=true
fi
if [[ "${PRODUCE_CONSUME_OK}" != "true" ]]; then
  echo "partition drill failed: post-recovery produce check failed (high watermark did not advance)" >&2
  echo "hwm_before=${HWM_BEFORE} hwm_after=${HWM_AFTER}" >&2
  exit 1
fi

INVARIANTS_STATUS="skipped"
INVARIANTS_OK="true"
INVARIANTS_PAYLOAD='{"skipped":true}'
case "${CHECK_INVARIANTS}" in
  off|OFF)
    INVARIANTS_STATUS="skipped"
    ;;
  auto|AUTO|require|REQUIRE)
    CURL_CMD=(curl -fsS -X POST "${LEDGER_BASE_URL}/v1/admin/invariants/check")
    if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
      CURL_CMD=(curl -fsS -H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}" -X POST "${LEDGER_BASE_URL}/v1/admin/invariants/check")
    fi
    if INVARIANTS_PAYLOAD="$("${CURL_CMD[@]}" 2>/tmp/network-partition-invariants.err)"; then
      INVARIANTS_STATUS="checked"
      INVARIANTS_OK="$("${PYTHON_BIN}" - "${INVARIANTS_PAYLOAD}" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print("true" if bool(payload.get("ok", False)) else "false")
PY
)"
      if [[ "${INVARIANTS_OK}" != "true" ]]; then
        echo "invariants check failed after network partition drill: ${INVARIANTS_PAYLOAD}" >&2
        exit 1
      fi
    else
      if [[ "${CHECK_INVARIANTS}" == "require" || "${CHECK_INVARIANTS}" == "REQUIRE" ]]; then
        echo "invariants check required but ledger endpoint unavailable" >&2
        cat /tmp/network-partition-invariants.err >&2 || true
        exit 1
      fi
      INVARIANTS_STATUS="unavailable_skipped"
      INVARIANTS_OK="true"
      INVARIANTS_PAYLOAD='{"skipped":true,"reason":"ledger_unavailable"}'
    fi
    ;;
  *)
    echo "invalid CHECK_INVARIANTS=${CHECK_INVARIANTS} (expected off|auto|require)" >&2
    exit 1
    ;;
esac
rm -f /tmp/network-partition-invariants.err

REPORT_FILE="${REPORT_FILE}" \
TOPIC="${TOPIC}" \
REQUESTED_METHOD="${ISOLATION_METHOD}" \
APPLIED_METHOD="${APPLIED_METHOD}" \
PARTITION_SECONDS="${PARTITION_SECONDS}" \
BEFORE_REACHABLE="${BEFORE_REACHABLE}" \
DURING_REACHABLE="${DURING_REACHABLE}" \
AFTER_REACHABLE="${AFTER_REACHABLE}" \
PRODUCE_CONSUME_OK="${PRODUCE_CONSUME_OK}" \
HWM_BEFORE="${HWM_BEFORE}" \
HWM_AFTER="${HWM_AFTER}" \
INVARIANTS_STATUS="${INVARIANTS_STATUS}" \
INVARIANTS_OK="${INVARIANTS_OK}" \
INVARIANTS_PAYLOAD="${INVARIANTS_PAYLOAD}" \
"${PYTHON_BIN}" - <<'PY'
import json
import os
from datetime import datetime, timezone

raw = os.environ.get("INVARIANTS_PAYLOAD", "{}")
try:
    invariants_payload = json.loads(raw)
except Exception:
    invariants_payload = {"raw": raw}

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": True,
    "scenario": {
        "topic": os.environ["TOPIC"],
        "requested_isolation_method": os.environ["REQUESTED_METHOD"],
        "applied_isolation_method": os.environ["APPLIED_METHOD"],
        "partition_seconds": int(os.environ["PARTITION_SECONDS"]),
    },
    "connectivity": {
        "before_partition_broker_reachable": os.environ["BEFORE_REACHABLE"].lower() == "true",
        "during_partition_broker_reachable": os.environ["DURING_REACHABLE"].lower() == "true",
        "after_recovery_broker_reachable": os.environ["AFTER_REACHABLE"].lower() == "true",
    },
    "recovery": {
        "produce_consume_ok": os.environ["PRODUCE_CONSUME_OK"].lower() == "true",
        "high_watermark_before": int(os.environ["HWM_BEFORE"]),
        "high_watermark_after": int(os.environ["HWM_AFTER"]),
    },
    "invariants": {
        "ok": os.environ["INVARIANTS_OK"].lower() == "true",
        "status": os.environ["INVARIANTS_STATUS"],
        "payload": invariants_payload,
    },
}

with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "${REPORT_FILE}" "${LATEST_FILE}"

echo "chaos_network_partition_report=${REPORT_FILE}"
echo "chaos_network_partition_latest=${LATEST_FILE}"
echo "chaos_network_partition_ok=true"
echo "chaos_network_partition_method=${APPLIED_METHOD}"
echo "chaos_network_partition_during_reachable=${DURING_REACHABLE}"
echo "invariants_ok=${INVARIANTS_OK}"
