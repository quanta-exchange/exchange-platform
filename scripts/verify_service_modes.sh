#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX_FILE="${MATRIX_FILE:-$ROOT_DIR/safety/service_modes.yaml}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/service-modes}"
TEST_FILTER="${TEST_FILTER:-service_mode_}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_FILE="$OUT_DIR/verify-service-modes-$TS_ID.log"
REPORT_FILE="$OUT_DIR/verify-service-modes-$TS_ID.json"
LATEST_FILE="$OUT_DIR/verify-service-modes-latest.json"

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
TEST_CODE=$?
set -e

"$PYTHON_BIN" - "$MATRIX_FILE" "$REPORT_FILE" "$LOG_FILE" "$TEST_CODE" "$TEST_FILTER" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

matrix_file = sys.argv[1]
report_file = sys.argv[2]
log_file = sys.argv[3]
test_code = int(sys.argv[4])
test_filter = sys.argv[5]

with open(matrix_file, "r", encoding="utf-8") as f:
    matrix = json.load(f)

modes = matrix.get("modes", [])
mode_map = {str(m.get("mode", "")).upper(): m for m in modes}

required = {
    "NORMAL": {"PLACE_ORDER", "CANCEL_ORDER"},
    "CANCEL_ONLY": {"CANCEL_ORDER"},
    "SOFT_HALT": {"CANCEL_ORDER"},
    "HARD_HALT": {"CANCEL_ORDER"},
}

matrix_errors = []
for mode_name, required_actions in required.items():
    entry = mode_map.get(mode_name)
    if not entry:
        matrix_errors.append(f"missing mode '{mode_name}' in matrix")
        continue
    if not bool(entry.get("implemented", False)):
        matrix_errors.append(f"mode '{mode_name}' must be marked implemented=true")
        continue
    allow = {str(x) for x in (entry.get("allow") or [])}
    missing = sorted(required_actions - allow)
    if missing:
        matrix_errors.append(f"mode '{mode_name}' missing actions: {', '.join(missing)}")

with open(log_file, "r", encoding="utf-8") as f:
    log = f.read()

passed = 0
failed = 0
match_ok = re.search(r"test result:\s+ok\.\s+(\d+)\s+passed;\s+(\d+)\s+failed;", log)
if match_ok:
    passed = int(match_ok.group(1))
    failed = int(match_ok.group(2))
else:
    match_fail = re.search(r"test result:\s+FAILED\.\s+(\d+)\s+passed;\s+(\d+)\s+failed;", log)
    if match_fail:
        passed = int(match_fail.group(1))
        failed = int(match_fail.group(2))

ok = test_code == 0 and failed == 0 and not matrix_errors

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "matrix_file": matrix_file,
    "matrix_errors": matrix_errors,
    "cargo_exit_code": test_code,
    "test_filter": test_filter,
    "passed": passed,
    "failed": failed,
    "log": log_file,
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")

if not ok:
    sys.exit(1)
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "verify_service_modes_report=$REPORT_FILE"
echo "verify_service_modes_latest=$LATEST_FILE"
echo "verify_service_modes_ok=true"
