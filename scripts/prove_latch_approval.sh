#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/latch}"
TEST_CLASS="${TEST_CLASS:-com.quanta.exchange.ledger.LedgerServiceIntegrationTest}"
TEST_NAMES="${TEST_NAMES:-safetyLatchRemainsActiveUntilManualRelease,latchReleaseRequiresDualApprovalWhenEnabled}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_FILE="$OUT_DIR/prove-latch-approval-$TS_ID.log"
REPORT_FILE="$OUT_DIR/prove-latch-approval-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-latch-approval-latest.json"

IFS=',' read -r -a TEST_ARRAY <<<"$TEST_NAMES"
if [[ "${#TEST_ARRAY[@]}" -eq 0 ]]; then
  echo "TEST_NAMES must include at least one test method" >&2
  exit 1
fi

declare -a GRADLE_ARGS=()
for name in "${TEST_ARRAY[@]}"; do
  trimmed="$(echo "$name" | xargs)"
  if [[ -z "$trimmed" ]]; then
    continue
  fi
  GRADLE_ARGS+=(--tests "${TEST_CLASS}.${trimmed}")
done

if [[ "${#GRADLE_ARGS[@]}" -eq 0 ]]; then
  echo "no valid tests resolved from TEST_NAMES=${TEST_NAMES}" >&2
  exit 1
fi

set +e
(
  cd "$ROOT_DIR"
  ./gradlew :services:ledger-service:test "${GRADLE_ARGS[@]}"
) >"$LOG_FILE" 2>&1
CODE=$?
set -e

"$PYTHON_BIN" - "$REPORT_FILE" "$LOG_FILE" "$CODE" "$TEST_CLASS" "$TEST_NAMES" "$ROOT_DIR/services/ledger-service/build/test-results/test" <<'PY'
import json
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

report_file = sys.argv[1]
log_file = sys.argv[2]
exit_code = int(sys.argv[3])
test_class = sys.argv[4]
test_names = [name.strip() for name in sys.argv[5].split(",") if name.strip()]
results_dir = sys.argv[6]

xml_file = os.path.join(results_dir, f"TEST-{test_class}.xml")
missing = list(test_names)
failed = []
passed = []
parse_error = None

if os.path.exists(xml_file):
    try:
        root = ET.parse(xml_file).getroot()
        cases = {}
        for case in root.findall("testcase"):
            raw_name = case.attrib.get("name", "")
            normalized = raw_name[:-2] if raw_name.endswith("()") else raw_name
            cases[raw_name] = case
            if normalized:
                cases[normalized] = case
        for name in test_names:
            case = cases.get(name)
            if case is None:
                continue
            if name in missing:
                missing.remove(name)
            has_failure = any(child.tag in ("failure", "error") for child in list(case))
            if has_failure:
                failed.append(name)
            else:
                passed.append(name)
    except Exception as exc:  # pragma: no cover - runtime guard
        parse_error = str(exc)
else:
    parse_error = f"missing_xml:{xml_file}"

ok = exit_code == 0 and not failed and not missing and parse_error is None

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "test_class": test_class,
    "requested_tests": test_names,
    "passed_tests": passed,
    "failed_tests": failed,
    "missing_tests": missing,
    "gradle_exit_code": exit_code,
    "log": log_file,
    "xml_report": xml_file,
    "parse_error": parse_error,
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

echo "prove_latch_approval_report=$REPORT_FILE"
echo "prove_latch_approval_latest=$LATEST_FILE"
echo "prove_latch_approval_ok=$OK"

if [[ "$OK" != "true" ]]; then
  exit 1
fi
