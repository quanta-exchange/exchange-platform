#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/idempotency}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PACKAGE="${PACKAGE:-./services/edge-gateway/internal/gateway}"
TEST_NAMES="${TEST_NAMES:-TestCreateOrderRejectsInvalidIdempotencyKey,TestCancelOrderRejectsInvalidIdempotencyKey,TestNormalizeIdempotencyKey}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_FILE="$OUT_DIR/prove-idempotency-key-format-$TS_ID.log"
REPORT_FILE="$OUT_DIR/prove-idempotency-key-format-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-idempotency-key-format-latest.json"

IFS=',' read -r -a TEST_ARRAY <<<"$TEST_NAMES"
if [[ "${#TEST_ARRAY[@]}" -eq 0 ]]; then
  echo "TEST_NAMES must include at least one test name" >&2
  exit 1
fi

declare -a FILTERED_TESTS=()
for name in "${TEST_ARRAY[@]}"; do
  trimmed="$(echo "$name" | xargs)"
  if [[ -n "$trimmed" ]]; then
    FILTERED_TESTS+=("$trimmed")
  fi
done

if [[ "${#FILTERED_TESTS[@]}" -eq 0 ]]; then
  echo "no valid tests resolved from TEST_NAMES=${TEST_NAMES}" >&2
  exit 1
fi

TEST_REGEX="$(printf "%s|" "${FILTERED_TESTS[@]}")"
TEST_REGEX="${TEST_REGEX%|}"
TEST_REGEX="^(${TEST_REGEX})$"

set +e
(
  cd "$ROOT_DIR"
  go test "$PACKAGE" -run "$TEST_REGEX" -json
) >"$LOG_FILE" 2>&1
GO_CODE=$?
set -e

"$PYTHON_BIN" - "$REPORT_FILE" "$LOG_FILE" "$GO_CODE" "$PACKAGE" "${FILTERED_TESTS[*]}" <<'PY'
import json
import sys
from datetime import datetime, timezone

report_file = sys.argv[1]
log_file = sys.argv[2]
go_code = int(sys.argv[3])
package = sys.argv[4]
requested_tests = [name for name in sys.argv[5].split(" ") if name]

status_by_test = {}
parse_errors = []

with open(log_file, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except Exception:
            continue
        test_name = event.get("Test")
        action = event.get("Action")
        if not test_name or not action:
            continue
        if test_name not in requested_tests:
            continue
        # Keep the latest terminal state for each requested test.
        if action in {"pass", "fail", "skip"}:
            status_by_test[test_name] = action
        elif action == "run" and test_name not in status_by_test:
            status_by_test[test_name] = "run"

passed_tests = sorted([name for name, status in status_by_test.items() if status == "pass"])
failed_tests = sorted(
    [name for name, status in status_by_test.items() if status in {"fail", "skip"}]
)
missing_tests = sorted([name for name in requested_tests if name not in status_by_test])

ok = go_code == 0 and not failed_tests and not missing_tests and not parse_errors

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "package": package,
    "requested_tests": requested_tests,
    "passed_tests": passed_tests,
    "failed_tests": failed_tests,
    "missing_tests": missing_tests,
    "go_exit_code": go_code,
    "log": log_file,
    "parse_errors": parse_errors,
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

echo "prove_idempotency_key_format_report=$REPORT_FILE"
echo "prove_idempotency_key_format_latest=$LATEST_FILE"
echo "prove_idempotency_key_format_ok=$OK"

if [[ "$OK" != "true" ]]; then
  exit 1
fi
