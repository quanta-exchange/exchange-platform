#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/exactly-once}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REPEATS="${REPEATS:-1000000}"
CONCURRENCY="${CONCURRENCY:-128}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/prove-exactly-once-million-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-exactly-once-million-latest.json"
LOG_FILE="$OUT_DIR/prove-exactly-once-million-$TS_ID.log"

set +e
(
  cd "$ROOT_DIR"
  REPEATS="$REPEATS" CONCURRENCY="$CONCURRENCY" REPORT_FILE="$REPORT_FILE" OUT_DIR="$OUT_DIR" ./scripts/exactly_once_stress.sh
) 2>&1 | tee "$LOG_FILE"
RUN_CODE=${PIPESTATUS[0]}
set -e

if [[ ! -f "$REPORT_FILE" ]]; then
  "$PYTHON_BIN" - "$REPORT_FILE" "$RUN_CODE" "$REPEATS" "$CONCURRENCY" "$LOG_FILE" <<'PY'
import json
import sys
from datetime import datetime, timezone

report_file = sys.argv[1]
run_code = int(sys.argv[2])
repeats = int(sys.argv[3])
concurrency = int(sys.argv[4])
log_file = sys.argv[5]

payload = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": False,
    "repeats": repeats,
    "concurrency": concurrency,
    "runner_exit_code": run_code,
    "error": "exactly_once_stress_report_missing",
    "log": log_file,
}
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY
fi

cp "$REPORT_FILE" "$LATEST_FILE"

OK="$(
  "$PYTHON_BIN" - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "prove_exactly_once_million_report=$REPORT_FILE"
echo "prove_exactly_once_million_latest=$LATEST_FILE"
echo "prove_exactly_once_million_ok=$OK"

if [[ "$OK" != "true" ]]; then
  exit 1
fi
