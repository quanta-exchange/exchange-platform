#!/usr/bin/env bash
set -euo pipefail

LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
OUT_DIR="${OUT_DIR:-build/invariants}"
INVARIANTS_CORE_MODE="${INVARIANTS_CORE_MODE:-auto}" # off|auto|require
CORE_WAL_DIR="${CORE_WAL_DIR:-/tmp/trading-core/wal}"
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
CORE_FILE="${OUT_DIR}/core-invariants.json"
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

core_enabled=true
case "${INVARIANTS_CORE_MODE}" in
  off|OFF)
    core_enabled=false
    ;;
  auto|AUTO|require|REQUIRE)
    ;;
  *)
    echo "invalid INVARIANTS_CORE_MODE=${INVARIANTS_CORE_MODE} (expected off|auto|require)" >&2
    exit 1
    ;;
esac

CORE_STATUS="skipped"
CORE_OK="true"
CORE_RECORDS="0"
CORE_SYMBOLS="0"
CORE_VIOLATIONS="0"
CORE_ERROR=""

if [[ "${core_enabled}" == "true" ]]; then
  if [[ -d "${CORE_WAL_DIR}" ]] && compgen -G "${CORE_WAL_DIR}/segment-*.wal" >/dev/null; then
    CORE_STATUS="checked"
    if CORE_STATS="$("${PYTHON_BIN}" - "${CORE_WAL_DIR}" <<'PY'
import glob
import json
import os
import struct
import sys
import zlib

wal_dir = sys.argv[1]
magic = b"XWALv1\0"

paths = sorted(glob.glob(os.path.join(wal_dir, "segment-*.wal")))
if not paths:
    print(json.dumps({"ok": True, "records": 0, "symbols": 0, "violations": []}))
    sys.exit(0)

violations = []
last_global = None
last_by_symbol = {}
records = 0
symbols = set()

for path in paths:
    with open(path, "rb") as f:
        blob = f.read()
    if not blob.startswith(magic):
        print(json.dumps({"ok": False, "error": f"invalid_magic:{path}"}))
        sys.exit(2)

    off = len(magic)
    while off + 4 <= len(blob):
        (size,) = struct.unpack_from("<I", blob, off)
        off += 4
        if off + size + 4 > len(blob):
            print(json.dumps({"ok": False, "error": f"truncated_frame:{path}"}))
            sys.exit(3)
        payload = blob[off : off + size]
        off += size
        (expected_crc,) = struct.unpack_from("<I", blob, off)
        off += 4

        actual_crc = zlib.crc32(payload) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            print(json.dumps({"ok": False, "error": f"crc_mismatch:{path}"}))
            sys.exit(4)

        try:
            rec = json.loads(payload.decode("utf-8"))
        except Exception:
            print(json.dumps({"ok": False, "error": f"decode_error:{path}"}))
            sys.exit(5)

        seq = int(rec.get("seq", 0))
        symbol = str(rec.get("symbol", "UNKNOWN"))
        records += 1
        symbols.add(symbol)

        if last_global is not None and seq <= last_global:
            violations.append(
                {
                    "kind": "global_non_monotonic",
                    "prev_seq": last_global,
                    "seq": seq,
                    "symbol": symbol,
                }
            )
        prev_symbol = last_by_symbol.get(symbol)
        if prev_symbol is not None and seq <= prev_symbol:
            violations.append(
                {
                    "kind": "symbol_non_monotonic",
                    "symbol": symbol,
                    "prev_seq": prev_symbol,
                    "seq": seq,
                }
            )

        last_global = seq
        last_by_symbol[symbol] = seq

result = {
    "ok": len(violations) == 0,
    "records": records,
    "symbols": len(symbols),
    "violations": violations[:20],
}
print(json.dumps(result))
PY
    )"; then
      CORE_OK="$("${PYTHON_BIN}" - "${CORE_STATS}" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print("true" if payload.get("ok", False) else "false")
PY
)"
      CORE_RECORDS="$("${PYTHON_BIN}" - "${CORE_STATS}" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(int(payload.get("records", 0)))
PY
)"
      CORE_SYMBOLS="$("${PYTHON_BIN}" - "${CORE_STATS}" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(int(payload.get("symbols", 0)))
PY
)"
      CORE_VIOLATIONS="$("${PYTHON_BIN}" - "${CORE_STATS}" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(len(payload.get("violations", [])))
PY
)"
      CORE_ERROR="$("${PYTHON_BIN}" - "${CORE_STATS}" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(payload.get("error", "") or "")
PY
)"
      export CORE_STATS
    else
      CORE_OK="false"
      CORE_ERROR="core_wal_parse_failure"
    fi
  else
    if [[ "${INVARIANTS_CORE_MODE}" == "require" || "${INVARIANTS_CORE_MODE}" == "REQUIRE" ]]; then
      CORE_STATUS="unavailable"
      CORE_OK="false"
      CORE_ERROR="wal_unavailable:${CORE_WAL_DIR}"
    else
      CORE_STATUS="unavailable_skipped"
      CORE_OK="true"
      CORE_ERROR="wal_unavailable:${CORE_WAL_DIR}"
    fi
  fi
fi

export LEDGER_FILE CLICKHOUSE_FILE CORE_FILE SUMMARY_FILE INVARIANTS_CLICKHOUSE_MODE INVARIANTS_CORE_MODE CLICKHOUSE_STATUS CLICKHOUSE_OK CLICKHOUSE_INVALID_TRADES CLICKHOUSE_INVALID_CANDLES CLICKHOUSE_ERROR CORE_STATUS CORE_OK CORE_RECORDS CORE_SYMBOLS CORE_VIOLATIONS CORE_ERROR
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

core_payload = {
    "mode": os.environ["INVARIANTS_CORE_MODE"].lower(),
    "status": os.environ["CORE_STATUS"],
    "ok": os.environ["CORE_OK"].lower() == "true",
    "records": int(os.environ["CORE_RECORDS"]),
    "symbols": int(os.environ["CORE_SYMBOLS"]),
    "violations": int(os.environ["CORE_VIOLATIONS"]),
    "error": os.environ["CORE_ERROR"] or None,
}
if os.environ.get("CORE_STATS"):
    try:
        detail = json.loads(os.environ["CORE_STATS"])
        core_payload["violation_examples"] = detail.get("violations", [])
    except Exception:
        pass

with open(os.environ["CLICKHOUSE_FILE"], "w", encoding="utf-8") as f:
    json.dump(clickhouse_payload, f, indent=2, sort_keys=True)
    f.write("\n")

with open(os.environ["CORE_FILE"], "w", encoding="utf-8") as f:
    json.dump(core_payload, f, indent=2, sort_keys=True)
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

core_mode = core_payload.get("mode", "auto")
core_ok = core_payload.get("ok", False)
core_status = core_payload.get("status")
if core_mode == "off":
    effective_core_ok = True
elif core_mode == "auto" and core_status == "unavailable_skipped":
    effective_core_ok = True
else:
    effective_core_ok = core_ok

overall_ok = ledger_ok and effective_clickhouse_ok and effective_core_ok
summary = {
    "ok": overall_ok,
    "ledger": ledger_payload,
    "clickhouse": clickhouse_payload,
    "core": core_payload,
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
    f"invalid_candles={clickhouse_payload.get('invalid_candles')} core_status={core_status} "
    f"core_violations={core_payload.get('violations')}",
    file=sys.stderr,
)
print(f"invariants_summary={os.environ['SUMMARY_FILE']}")
sys.exit(1)
PY
