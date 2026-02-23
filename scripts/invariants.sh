#!/usr/bin/env bash
set -euo pipefail

LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
OUT_DIR="${OUT_DIR:-build/invariants}"
INVARIANTS_CLICKHOUSE_MODE="${INVARIANTS_CLICKHOUSE_MODE:-auto}" # off|auto|require
CLICKHOUSE_HTTP_URL="${CLICKHOUSE_HTTP_URL:-http://localhost:28123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-exchange}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-exchange}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${OUT_DIR}"

ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

LEDGER_RESULT="$(curl -fsS "${ADMIN_HEADERS[@]}" -X POST "${LEDGER_BASE_URL}/v1/admin/invariants/check")"
LEDGER_FILE="${OUT_DIR}/ledger-invariants.json"
echo "${LEDGER_RESULT}" > "${LEDGER_FILE}"

CLICKHOUSE_FILE="${OUT_DIR}/clickhouse-invariants.json"
SUMMARY_FILE="${OUT_DIR}/invariants-summary.json"

clickhouse_query() {
  local sql="$1"
  curl -fsS "${CLICKHOUSE_HTTP_URL}/?database=exchange&user=${CLICKHOUSE_USER}&password=${CLICKHOUSE_PASSWORD}" \
    --data-binary "${sql}"
}

clickhouse_enabled=true
case "${INVARIANTS_CLICKHOUSE_MODE}" in
  off|OFF)
    clickhouse_enabled=false
    ;;
  auto|AUTO|require|REQUIRE)
    ;;
  *)
    echo "invalid INVARIANTS_CLICKHOUSE_MODE=${INVARIANTS_CLICKHOUSE_MODE} (expected off|auto|require)" >&2
    exit 1
    ;;
esac

CLICKHOUSE_STATUS="skipped"
CLICKHOUSE_OK="true"
CLICKHOUSE_INVALID_TRADES="-1"
CLICKHOUSE_INVALID_CANDLES="-1"
CLICKHOUSE_ERROR=""

if [[ "${clickhouse_enabled}" == "true" ]]; then
  if HEALTH_RESP="$(clickhouse_query "SELECT 1 FORMAT TabSeparatedRaw" 2>/tmp/invariants-clickhouse.err)"; then
    if [[ "${HEALTH_RESP}" == "1" ]]; then
      CLICKHOUSE_STATUS="checked"
      if TRADES_RESP="$(clickhouse_query "SELECT count() FROM exchange.trades WHERE price <= 0 OR quantity <= 0 OR quote_amount < 0 FORMAT TabSeparatedRaw" 2>/tmp/invariants-clickhouse.err)"; then
        CLICKHOUSE_INVALID_TRADES="$(echo "${TRADES_RESP}" | tr -d '[:space:]')"
      else
        CLICKHOUSE_OK="false"
        CLICKHOUSE_ERROR="$(cat /tmp/invariants-clickhouse.err 2>/dev/null || true)"
      fi
      if CANDLES_RESP="$(clickhouse_query "SELECT count() FROM exchange.candles WHERE high < low OR open < low OR open > high OR close < low OR close > high OR volume < 0 OR close_time < open_time FORMAT TabSeparatedRaw" 2>/tmp/invariants-clickhouse.err)"; then
        CLICKHOUSE_INVALID_CANDLES="$(echo "${CANDLES_RESP}" | tr -d '[:space:]')"
      else
        CLICKHOUSE_OK="false"
        CLICKHOUSE_ERROR="$(cat /tmp/invariants-clickhouse.err 2>/dev/null || true)"
      fi
      if [[ "${CLICKHOUSE_INVALID_TRADES}" != "0" || "${CLICKHOUSE_INVALID_CANDLES}" != "0" ]]; then
        CLICKHOUSE_OK="false"
      fi
    else
      CLICKHOUSE_STATUS="unavailable"
      CLICKHOUSE_OK="false"
      CLICKHOUSE_ERROR="unexpected_health_response:${HEALTH_RESP}"
    fi
  else
    CLICKHOUSE_STATUS="unavailable"
    if [[ "${INVARIANTS_CLICKHOUSE_MODE}" == "require" || "${INVARIANTS_CLICKHOUSE_MODE}" == "REQUIRE" ]]; then
      CLICKHOUSE_OK="false"
    else
      CLICKHOUSE_OK="true"
      CLICKHOUSE_STATUS="unavailable_skipped"
    fi
    CLICKHOUSE_ERROR="$(cat /tmp/invariants-clickhouse.err 2>/dev/null || true)"
  fi
fi

rm -f /tmp/invariants-clickhouse.err

export LEDGER_FILE CLICKHOUSE_FILE SUMMARY_FILE INVARIANTS_CLICKHOUSE_MODE CLICKHOUSE_STATUS CLICKHOUSE_OK CLICKHOUSE_INVALID_TRADES CLICKHOUSE_INVALID_CANDLES CLICKHOUSE_ERROR

"${PYTHON_BIN}" - <<'PY'
import json
import os
import sys

with open(os.environ["LEDGER_FILE"], "r", encoding="utf-8") as f:
    ledger_payload = json.load(f)

clickhouse_payload = {
    "mode": os.environ["INVARIANTS_CLICKHOUSE_MODE"].lower(),
    "status": os.environ["CLICKHOUSE_STATUS"],
    "ok": os.environ["CLICKHOUSE_OK"].lower() == "true",
    "invalid_trades": int(os.environ["CLICKHOUSE_INVALID_TRADES"]),
    "invalid_candles": int(os.environ["CLICKHOUSE_INVALID_CANDLES"]),
    "error": os.environ["CLICKHOUSE_ERROR"] or None,
}

with open(os.environ["CLICKHOUSE_FILE"], "w", encoding="utf-8") as f:
    json.dump(clickhouse_payload, f, indent=2, sort_keys=True)
    f.write("\n")

ledger_ok = bool(ledger_payload.get("ok", False))
clickhouse_mode = clickhouse_payload.get("mode", "auto")
clickhouse_ok = clickhouse_payload.get("ok", False)
clickhouse_status = clickhouse_payload.get("status")

if clickhouse_mode == "off":
    effective_clickhouse_ok = True
elif clickhouse_mode == "auto" and clickhouse_status == "unavailable_skipped":
    effective_clickhouse_ok = True
else:
    effective_clickhouse_ok = clickhouse_ok

overall_ok = ledger_ok and effective_clickhouse_ok
summary = {
    "ok": overall_ok,
    "ledger": ledger_payload,
    "clickhouse": clickhouse_payload,
}
with open(os.environ["SUMMARY_FILE"], "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")

if overall_ok:
    print("invariants_success=true")
    print(f"invariants_summary={os.environ['SUMMARY_FILE']}")
    sys.exit(0)

print(
    f"invariants_success=false ledger_violations={ledger_payload.get('violations', [])} "
    f"clickhouse_status={clickhouse_status} invalid_trades={clickhouse_payload.get('invalid_trades')} "
    f"invalid_candles={clickhouse_payload.get('invalid_candles')}",
    file=sys.stderr,
)
print(f"invariants_summary={os.environ['SUMMARY_FILE']}")
sys.exit(1)
PY
