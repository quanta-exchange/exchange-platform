#!/usr/bin/env bash
set -euo pipefail

LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
REPEATS="${REPEATS:-10000}"
CONCURRENCY="${CONCURRENCY:-32}"
SYMBOL="${SYMBOL:-BTC-KRW}"
PRICE="${PRICE:-100}"
QTY="${QTY:-1}"
QUOTE_AMOUNT="${QUOTE_AMOUNT:-100}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
OUT_DIR="${OUT_DIR:-build/exactly-once}"
REPORT_FILE="${REPORT_FILE:-${OUT_DIR}/exactly-once-stress.json}"

if ! [[ "${REPEATS}" =~ ^[0-9]+$ ]] || [[ "${REPEATS}" -lt 1 ]]; then
  echo "REPEATS must be positive integer" >&2
  exit 1
fi
if ! [[ "${CONCURRENCY}" =~ ^[0-9]+$ ]] || [[ "${CONCURRENCY}" -lt 1 ]]; then
  echo "CONCURRENCY must be positive integer" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

RUN_ID="$(date +%s)"
BUYER_ID="exactly-buyer-${RUN_ID}"
SELLER_ID="exactly-seller-${RUN_ID}"
BUY_ORDER_ID="exactly-buy-order-${RUN_ID}"
SELL_ORDER_ID="exactly-sell-order-${RUN_ID}"
TRADE_ID="exactly-trade-${RUN_ID}"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

reserve_payload() {
  local order_id="$1"
  local user_id="$2"
  local side="$3"
  local amount="$4"
  local seq="$5"
  cat <<JSON
{
  "envelope": {
    "eventId": "evt-${order_id}",
    "eventVersion": 1,
    "symbol": "${SYMBOL}",
    "seq": ${seq},
    "occurredAt": "$(now_iso)",
    "correlationId": "corr-${order_id}",
    "causationId": "cause-${order_id}"
  },
  "orderId": "${order_id}",
  "userId": "${user_id}",
  "side": "${side}",
  "amount": ${amount}
}
JSON
}

trade_payload() {
  cat <<JSON
{
  "envelope": {
    "eventId": "evt-${TRADE_ID}",
    "eventVersion": 1,
    "symbol": "${SYMBOL}",
    "seq": 3,
    "occurredAt": "$(now_iso)",
    "correlationId": "corr-${TRADE_ID}",
    "causationId": "cause-${TRADE_ID}"
  },
  "tradeId": "${TRADE_ID}",
  "buyerUserId": "${BUYER_ID}",
  "sellerUserId": "${SELLER_ID}",
  "price": ${PRICE},
  "quantity": ${QTY},
  "quoteAmount": ${QUOTE_AMOUNT},
  "feeBuyer": 0,
  "feeSeller": 0
}
JSON
}

post_json() {
  local path="$1"
  local payload="$2"
  curl -fsS -X POST "${LEDGER_BASE_URL}${path}" \
    -H 'Content-Type: application/json' \
    -d "${payload}"
}

admin_get() {
  local path="$1"
  if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
    curl -fsS -H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}" "${LEDGER_BASE_URL}${path}"
    return
  fi
  curl -fsS "${LEDGER_BASE_URL}${path}"
}

echo "[exactly-once] reserve buyer quote hold"
BUY_RESERVE="$(post_json "/v1/internal/orders/reserve" "$(reserve_payload "${BUY_ORDER_ID}" "${BUYER_ID}" "BUY" "${QUOTE_AMOUNT}" 1)")"
echo "buyer_reserve=${BUY_RESERVE}"

echo "[exactly-once] reserve seller base hold"
SELL_RESERVE="$(post_json "/v1/internal/orders/reserve" "$(reserve_payload "${SELL_ORDER_ID}" "${SELLER_ID}" "SELL" "${QTY}" 2)")"
echo "seller_reserve=${SELL_RESERVE}"

TRADE_PAYLOAD="$(trade_payload)"
export LEDGER_BASE_URL TRADE_PAYLOAD REPEATS CONCURRENCY PYTHON_BIN

RESULT="$("${PYTHON_BIN}" - <<'PY'
import concurrent.futures
import json
import os
import urllib.request

url = os.environ["LEDGER_BASE_URL"].rstrip("/") + "/v1/internal/trades/executed"
payload = os.environ["TRADE_PAYLOAD"].encode("utf-8")
repeats = int(os.environ["REPEATS"])
concurrency = int(os.environ["CONCURRENCY"])

def call_once(_):
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return bool(data.get("applied", False)), data.get("reason", "")
    except Exception as exc:  # pragma: no cover - runtime guard
        return False, f"error:{exc}"

applied_true = 0
duplicate = 0
other = 0
errors = 0

with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as ex:
    for applied, reason in ex.map(call_once, range(repeats)):
        if applied:
            applied_true += 1
        elif reason == "duplicate":
            duplicate += 1
        elif str(reason).startswith("error:"):
            errors += 1
        else:
            other += 1

print(json.dumps({
    "applied_true": applied_true,
    "duplicate": duplicate,
    "other": other,
    "errors": errors,
    "repeats": repeats
}))
PY
)"

echo "trade_injection_summary=${RESULT}"

BALANCES="$(admin_get "/v1/admin/balances")"
export BALANCES BUYER_ID SELLER_ID QUOTE_AMOUNT QTY RESULT REPORT_FILE SYMBOL REPEATS CONCURRENCY RUN_ID TRADE_ID

"${PYTHON_BIN}" - <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

summary = json.loads(os.environ["RESULT"])
balances = json.loads(os.environ["BALANCES"]).get("balances", {})
buyer = os.environ["BUYER_ID"]
seller = os.environ["SELLER_ID"]
quote_amount = int(os.environ["QUOTE_AMOUNT"])
qty = int(os.environ["QTY"])
report_file = os.environ["REPORT_FILE"]

expected = {
    f"user:{buyer}:KRW:HOLD:KRW": 0,
    f"user:{seller}:BTC:HOLD:BTC": 0,
    f"user:{buyer}:BTC:AVAILABLE:BTC": qty,
    f"user:{seller}:KRW:AVAILABLE:KRW": quote_amount,
}
mismatches = {}
ok = True

if summary.get("applied_true") != 1:
    ok = False
    mismatches["applied_true"] = {
        "expected": 1,
        "actual": summary.get("applied_true"),
    }
if summary.get("errors", 0) != 0 or summary.get("other", 0) != 0:
    ok = False
    mismatches["submission_errors"] = {
        "errors": int(summary.get("errors", 0)),
        "other": int(summary.get("other", 0)),
    }

for key, want in expected.items():
    got = int(balances.get(key, 0))
    if got != want:
        ok = False
        mismatches[key] = {"expected": want, "actual": got}

report = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": os.environ["RUN_ID"],
    "ok": ok,
    "ledger_base_url": os.environ["LEDGER_BASE_URL"],
    "symbol": os.environ["SYMBOL"],
    "trade_id": os.environ["TRADE_ID"],
    "repeats": int(os.environ["REPEATS"]),
    "concurrency": int(os.environ["CONCURRENCY"]),
    "summary": {
        "applied_true": int(summary.get("applied_true", 0)),
        "duplicate": int(summary.get("duplicate", 0)),
        "errors": int(summary.get("errors", 0)),
        "other": int(summary.get("other", 0)),
    },
    "expected_balances": expected,
    "mismatches": mismatches,
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")

if not ok:
    print(f"exactly-once verification failed: {json.dumps(mismatches, sort_keys=True)}", file=sys.stderr)
    sys.exit(1)

print("exactly_once_stress_success=true")
print(f"trade_applied_once={summary['applied_true']}")
print(f"duplicate_blocked={summary['duplicate']}")
print(f"exactly_once_report={report_file}")
PY
