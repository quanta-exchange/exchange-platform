#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/idempotency}"
TEST_FILTER="${TEST_FILTER:-idempotency_}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_FILE="$OUT_DIR/prove-idempotency-$TS_ID.log"
REPORT_FILE="$OUT_DIR/prove-idempotency-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-idempotency-latest.json"

if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  export SDKROOT
  export CFLAGS="-isysroot ${SDKROOT} ${CFLAGS:-}"
  export CXXFLAGS="-isysroot ${SDKROOT} -I${SDKROOT}/usr/include/c++/v1 ${CXXFLAGS:-}"
fi

set +e
(
  cd "$ROOT_DIR"
  cargo test -p trading-core "$TEST_FILTER" -- --nocapture
) >"$LOG_FILE" 2>&1
CODE=$?
set -e

"$PYTHON_BIN" - "$REPORT_FILE" "$LOG_FILE" "$CODE" "$TEST_FILTER" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

report_file = sys.argv[1]
log_file = sys.argv[2]
exit_code = int(sys.argv[3])
test_filter = sys.argv[4]

passed = 0
failed = 0
with open(log_file, "r", encoding="utf-8") as f:
    text = f.read()
    m = re.search(r"test result:\s+ok\.\s+(\d+)\s+passed;\s+(\d+)\s+failed;", text)
    if m:
        passed = int(m.group(1))
        failed = int(m.group(2))
    else:
        m2 = re.search(r"test result:\s+FAILED\.\s+(\d+)\s+passed;\s+(\d+)\s+failed;", text)
        if m2:
            passed = int(m2.group(1))
            failed = int(m2.group(2))

ok = exit_code == 0 and failed == 0 and passed > 0

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "test_filter": test_filter,
    "cargo_exit_code": exit_code,
    "passed": passed,
    "failed": failed,
    "log": log_file,
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
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

echo "prove_idempotency_report=$REPORT_FILE"
echo "prove_idempotency_latest=$LATEST_FILE"
echo "prove_idempotency_ok=$OK"

if [[ "$OK" != "true" ]]; then
  exit 1
fi
