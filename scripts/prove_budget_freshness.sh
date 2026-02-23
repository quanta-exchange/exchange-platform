#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/safety}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
PROVE_DIR="$OUT_DIR/prove-budget-freshness-$TS_ID"
mkdir -p "$PROVE_DIR"

TEST_REPORT_FILE="$PROVE_DIR/load-report.json"
TEST_BUDGET_FILE="$PROVE_DIR/budgets.json"
STALE_LOG="$PROVE_DIR/stale-run.log"
FRESH_LOG="$PROVE_DIR/fresh-run.log"
REPORT_FILE="$OUT_DIR/prove-budget-freshness-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-budget-freshness-latest.json"

REPORT_REL="$(
  "$PYTHON_BIN" - "$ROOT_DIR" "$TEST_REPORT_FILE" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1]).resolve()
path = pathlib.Path(sys.argv[2]).resolve()
print(path.relative_to(root))
PY
)"

cat >"$TEST_BUDGET_FILE" <<EOF
{
  "freshness": {
    "defaultMaxAgeSeconds": 60
  },
  "budgets": {
    "load": {
      "required": true,
      "orderP99MsMax": 50.0,
      "orderErrorRateMax": 0.01
    }
  },
  "reports": {
    "load": "$REPORT_REL"
  }
}
EOF

cat >"$TEST_REPORT_FILE" <<EOF
{
  "generated_at_utc": "2000-01-01T00:00:00Z",
  "order_p99_ms": 10.0,
  "order_error_rate": 0.0
}
EOF

set +e
"$ROOT_DIR/scripts/safety_budget_check.sh" --budget-file "$TEST_BUDGET_FILE" --out-dir "$PROVE_DIR/stale" >"$STALE_LOG" 2>&1
STALE_CODE=$?
set -e

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
cat >"$TEST_REPORT_FILE" <<EOF
{
  "generated_at_utc": "$NOW_UTC",
  "order_p99_ms": 10.0,
  "order_error_rate": 0.0
}
EOF

set +e
"$ROOT_DIR/scripts/safety_budget_check.sh" --budget-file "$TEST_BUDGET_FILE" --out-dir "$PROVE_DIR/fresh" >"$FRESH_LOG" 2>&1
FRESH_CODE=$?
set -e

"$PYTHON_BIN" - "$REPORT_FILE" "$PROVE_DIR/stale/safety-budget-latest.json" "$PROVE_DIR/fresh/safety-budget-latest.json" "$STALE_CODE" "$FRESH_CODE" "$STALE_LOG" "$FRESH_LOG" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
stale_latest = pathlib.Path(sys.argv[2]).resolve()
fresh_latest = pathlib.Path(sys.argv[3]).resolve()
stale_code = int(sys.argv[4])
fresh_code = int(sys.argv[5])
stale_log = pathlib.Path(sys.argv[6]).resolve()
fresh_log = pathlib.Path(sys.argv[7]).resolve()

stale_payload = {}
fresh_payload = {}
if stale_latest.exists():
    stale_payload = json.loads(stale_latest.read_text(encoding="utf-8"))
if fresh_latest.exists():
    fresh_payload = json.loads(fresh_latest.read_text(encoding="utf-8"))

stale_violations = stale_payload.get("violations", []) if isinstance(stale_payload, dict) else []
fresh_violations = fresh_payload.get("violations", []) if isinstance(fresh_payload, dict) else []

stale_failed = stale_code != 0 and any("stale_report" in v for v in stale_violations)
fresh_passed = fresh_code == 0 and bool(fresh_payload.get("ok", False))

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": stale_failed and fresh_passed,
    "stale_run": {
        "exit_code": stale_code,
        "detected_staleness": stale_failed,
        "violations": stale_violations,
        "latest_report": str(stale_latest),
        "log": str(stale_log),
    },
    "fresh_run": {
        "exit_code": fresh_code,
        "passed": fresh_passed,
        "violations": fresh_violations,
        "latest_report": str(fresh_latest),
        "log": str(fresh_log),
    },
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

OK="$("$PYTHON_BIN" - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "prove_budget_freshness_report=$REPORT_FILE"
echo "prove_budget_freshness_latest=$LATEST_FILE"
echo "prove_budget_freshness_ok=$OK"

if [[ "$OK" != "true" ]]; then
  exit 1
fi
