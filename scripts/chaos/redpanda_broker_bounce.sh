#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/infra/compose/docker-compose.yml"
RUN_ID="${RUN_ID:-$(date -u +"%s")-$RANDOM}"
TOPIC="${TOPIC:-chaos.redpanda.bounce.${RUN_ID}.v1}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/build/chaos}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/redpanda-broker-bounce.json}"
LATEST_FILE="${LATEST_FILE:-${OUT_DIR}/redpanda-broker-bounce-latest.json}"
LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
CHAOS_REDPANDA_CHECK_INVARIANTS="${CHAOS_REDPANDA_CHECK_INVARIANTS:-auto}" # off|auto|require
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${OUT_DIR}"

ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

curl_with_admin_headers() {
  if [[ "${#ADMIN_HEADERS[@]}" -gt 0 ]]; then
    curl -fsS "${ADMIN_HEADERS[@]}" "$@"
    return
  fi
  curl -fsS "$@"
}

require_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}. ${hint}" >&2
    exit 1
  fi
}

require_cmd docker "Install Docker Desktop."
require_cmd "${PYTHON_BIN}" "Install Python 3."
require_cmd curl "Install curl."

docker compose -f "${COMPOSE_FILE}" up -d redpanda redpanda-init

echo "[chaos:redpanda] wait cluster ready"
for _ in {1..90}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null
BROKER_REACHABLE_BEFORE_STOP="true"
BROKER_UNAVAILABLE_DURING_STOP="false"
BROKER_REACHABLE_AFTER_RESTART="false"
POST_RESTART_CONSUME_OK="false"

echo "[chaos:redpanda] create topic and publish baseline"
docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic create "${TOPIC}" -p 1 -r 1 >/dev/null 2>&1 || true
printf '{"msg":"before-bounce","run_id":"%s"}\n' "${RUN_ID}" | docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic produce "${TOPIC}" >/dev/null

echo "[chaos:redpanda] stop broker"
docker compose -f "${COMPOSE_FILE}" stop redpanda >/dev/null
sleep 3

if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
  echo "expected broker to be unavailable after stop" >&2
  exit 1
fi
BROKER_UNAVAILABLE_DURING_STOP="true"

echo "[chaos:redpanda] restart broker"
docker compose -f "${COMPOSE_FILE}" start redpanda >/dev/null

for _ in {1..90}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null
BROKER_REACHABLE_AFTER_RESTART="true"

echo "[chaos:redpanda] publish and consume after restart"
AFTER_PAYLOAD="{\"msg\":\"after-bounce\",\"run_id\":\"${RUN_ID}\"}"
printf '%s\n' "${AFTER_PAYLOAD}" | docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic produce "${TOPIC}" >/dev/null
CONSUMED="$(docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic consume "${TOPIC}" -n 1 -o -1 -f '%v\n' || true)"
if ! grep -q "\"run_id\":\"${RUN_ID}\"" <<<"${CONSUMED}"; then
  echo "did not observe post-bounce message on consume output" >&2
  echo "${CONSUMED}" >&2
  exit 1
fi
POST_RESTART_CONSUME_OK="true"

INVARIANTS_STATUS="skipped"
INVARIANTS_OK="true"
INVARIANTS_PAYLOAD='{"skipped":true}'
case "${CHAOS_REDPANDA_CHECK_INVARIANTS}" in
  off|OFF)
    INVARIANTS_STATUS="skipped"
    ;;
  auto|AUTO|require|REQUIRE)
    if INVARIANTS_PAYLOAD="$(curl_with_admin_headers -X POST "${LEDGER_BASE_URL}/v1/admin/invariants/check" 2>/tmp/redpanda-bounce-invariants.err)"; then
      INVARIANTS_STATUS="checked"
      INVARIANTS_OK="$("${PYTHON_BIN}" - "${INVARIANTS_PAYLOAD}" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
print("true" if bool(payload.get("ok", False)) else "false")
PY
)"
      if [[ "${INVARIANTS_OK}" != "true" ]]; then
        echo "invariants check failed after redpanda bounce: ${INVARIANTS_PAYLOAD}" >&2
        exit 1
      fi
    else
      if [[ "${CHAOS_REDPANDA_CHECK_INVARIANTS}" == "require" || "${CHAOS_REDPANDA_CHECK_INVARIANTS}" == "REQUIRE" ]]; then
        echo "invariants check required but ledger endpoint unavailable" >&2
        cat /tmp/redpanda-bounce-invariants.err >&2 || true
        exit 1
      fi
      INVARIANTS_STATUS="unavailable_skipped"
      INVARIANTS_OK="true"
      INVARIANTS_PAYLOAD='{"skipped":true,"reason":"ledger_unavailable"}'
    fi
    ;;
  *)
    echo "invalid CHAOS_REDPANDA_CHECK_INVARIANTS=${CHAOS_REDPANDA_CHECK_INVARIANTS} (expected off|auto|require)" >&2
    exit 1
    ;;
esac

rm -f /tmp/redpanda-bounce-invariants.err

REPORT_FILE="${REPORT_FILE}" \
LATEST_FILE="${LATEST_FILE}" \
TOPIC="${TOPIC}" \
RUN_ID="${RUN_ID}" \
LEDGER_BASE_URL="${LEDGER_BASE_URL}" \
INVARIANTS_STATUS="${INVARIANTS_STATUS}" \
INVARIANTS_OK="${INVARIANTS_OK}" \
INVARIANTS_PAYLOAD="${INVARIANTS_PAYLOAD}" \
BROKER_REACHABLE_BEFORE_STOP="${BROKER_REACHABLE_BEFORE_STOP}" \
BROKER_UNAVAILABLE_DURING_STOP="${BROKER_UNAVAILABLE_DURING_STOP}" \
BROKER_REACHABLE_AFTER_RESTART="${BROKER_REACHABLE_AFTER_RESTART}" \
POST_RESTART_CONSUME_OK="${POST_RESTART_CONSUME_OK}" \
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
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": True,
    "scenario": {
        "topic": os.environ["TOPIC"],
        "run_id": os.environ["RUN_ID"],
        "ledger_base_url": os.environ["LEDGER_BASE_URL"],
        "check_invariants": os.environ["INVARIANTS_STATUS"],
    },
    "connectivity": {
        "before_stop_broker_reachable": os.environ["BROKER_REACHABLE_BEFORE_STOP"].lower() == "true",
        "during_stop_broker_reachable": os.environ["BROKER_UNAVAILABLE_DURING_STOP"].lower() != "true",
        "after_restart_broker_reachable": os.environ["BROKER_REACHABLE_AFTER_RESTART"].lower() == "true",
        "post_restart_consume_ok": os.environ["POST_RESTART_CONSUME_OK"].lower() == "true",
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

with open(os.environ["LATEST_FILE"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "redpanda_broker_bounce_success=true"
echo "redpanda_broker_bounce_report=${REPORT_FILE}"
echo "redpanda_broker_bounce_latest=${LATEST_FILE}"
echo "redpanda_broker_bounce_during_reachable=$([[ "${BROKER_UNAVAILABLE_DURING_STOP}" == "true" ]] && echo "false" || echo "true")"
echo "redpanda_broker_bounce_recovered=${BROKER_REACHABLE_AFTER_RESTART}"
echo "invariants_ok=${INVARIANTS_OK}"
