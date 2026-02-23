#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/idempotency-latch-${TS_ID}}"
LOG_FILE="$OUT_DIR/idempotency-latch.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/idempotency-latch-latest.json"

RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=idempotency_latch_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  IDEMPOTENCY_OUTPUT="$("$ROOT_DIR/scripts/prove_idempotency_scope.sh" 2>&1)"
  IDEMPOTENCY_CODE=$?
  set -e
  echo "$IDEMPOTENCY_OUTPUT"

  IDEMPOTENCY_OK="$(extract_value "prove_idempotency_ok" "$IDEMPOTENCY_OUTPUT")"
  IDEMPOTENCY_REPORT="$(extract_value "prove_idempotency_latest" "$IDEMPOTENCY_OUTPUT")"
  if [[ -z "$IDEMPOTENCY_REPORT" ]]; then
    IDEMPOTENCY_REPORT="$(extract_value "prove_idempotency_report" "$IDEMPOTENCY_OUTPUT")"
  fi
  if [[ -z "$IDEMPOTENCY_OK" ]]; then
    if [[ "$IDEMPOTENCY_CODE" -eq 0 ]]; then
      IDEMPOTENCY_OK="true"
    else
      IDEMPOTENCY_OK="false"
    fi
  fi

  set +e
  LATCH_OUTPUT="$("$ROOT_DIR/scripts/prove_latch_approval.sh" 2>&1)"
  LATCH_CODE=$?
  set -e
  echo "$LATCH_OUTPUT"

  LATCH_OK="$(extract_value "prove_latch_approval_ok" "$LATCH_OUTPUT")"
  LATCH_REPORT="$(extract_value "prove_latch_approval_latest" "$LATCH_OUTPUT")"
  if [[ -z "$LATCH_REPORT" ]]; then
    LATCH_REPORT="$(extract_value "prove_latch_approval_report" "$LATCH_OUTPUT")"
  fi
  if [[ -z "$LATCH_OK" ]]; then
    if [[ "$LATCH_CODE" -eq 0 ]]; then
      LATCH_OK="true"
    else
      LATCH_OK="false"
    fi
  fi

  BUDGET_OK="false"
  set +e
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR" >"$OUT_DIR/safety-budget.log" 2>&1
  BUDGET_CODE=$?
  set -e
  if [[ "$BUDGET_CODE" -eq 0 ]]; then
    BUDGET_OK="true"
  fi

  SUMMARY_FILE="$OUT_DIR/idempotency-latch-summary.json"
  python3 - "$SUMMARY_FILE" "$IDEMPOTENCY_REPORT" "$LATCH_REPORT" "$IDEMPOTENCY_CODE" "$LATCH_CODE" "$BUDGET_OK" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
idempotency_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
latch_report = pathlib.Path(sys.argv[3]).resolve() if sys.argv[3] else None
idempotency_exit_code = int(sys.argv[4])
latch_exit_code = int(sys.argv[5])
budget_ok = sys.argv[6].lower() == "true"

def read_json(path):
    if not path or not path.exists():
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

idempotency_payload = read_json(idempotency_report)
latch_payload = read_json(latch_report)

idempotency_ok = bool(idempotency_payload.get("ok", False))
idempotency_passed = int(idempotency_payload.get("passed", 0) or 0)
idempotency_failed = int(idempotency_payload.get("failed", 0) or 0)
latch_ok = bool(latch_payload.get("ok", False))
latch_missing_tests_count = len(latch_payload.get("missing_tests", []) or [])
latch_failed_tests_count = len(latch_payload.get("failed_tests", []) or [])

recommendation = "NO_ACTION"
if idempotency_exit_code != 0 or not idempotency_ok:
    recommendation = "INVESTIGATE_IDEMPOTENCY_SCOPE"
elif latch_exit_code != 0 or not latch_ok:
    recommendation = "INVESTIGATE_LATCH_APPROVAL"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "idempotency_report": str(idempotency_report) if idempotency_report else None,
    "idempotency_exit_code": idempotency_exit_code,
    "idempotency_ok": idempotency_ok,
    "idempotency_passed": idempotency_passed,
    "idempotency_failed": idempotency_failed,
    "latch_report": str(latch_report) if latch_report else None,
    "latch_exit_code": latch_exit_code,
    "latch_ok": latch_ok,
    "latch_missing_tests_count": latch_missing_tests_count,
    "latch_failed_tests_count": latch_failed_tests_count,
    "budget_ok": budget_ok,
    "recommended_action": recommendation,
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  cp "$SUMMARY_FILE" "$LATEST_SUMMARY_FILE"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  RECOMMENDED_ACTION="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("recommended_action", "UNKNOWN"))
PY
  )"
  SUMMARY_IDEMPOTENCY_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("idempotency_ok") else "false")
PY
  )"
  SUMMARY_IDEMPOTENCY_PASSED="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("idempotency_passed", 0)))
PY
  )"
  SUMMARY_IDEMPOTENCY_FAILED="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("idempotency_failed", 0)))
PY
  )"
  SUMMARY_LATCH_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("latch_ok") else "false")
PY
  )"
  SUMMARY_LATCH_MISSING_TESTS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("latch_missing_tests_count", 0)))
PY
  )"
  SUMMARY_LATCH_FAILED_TESTS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("latch_failed_tests_count", 0)))
PY
  )"

  RUNBOOK_OK=true
  if [[ "$IDEMPOTENCY_CODE" -ne 0 && "$RUNBOOK_ALLOW_PROOF_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$LATCH_CODE" -ne 0 && "$RUNBOOK_ALLOW_PROOF_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$BUDGET_OK" != "true" && "$RUNBOOK_ALLOW_BUDGET_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi

  echo "idempotency_scope_proof_exit_code=$IDEMPOTENCY_CODE"
  echo "idempotency_scope_proof_ok=$SUMMARY_IDEMPOTENCY_OK"
  echo "idempotency_scope_proof_passed=$SUMMARY_IDEMPOTENCY_PASSED"
  echo "idempotency_scope_proof_failed=$SUMMARY_IDEMPOTENCY_FAILED"
  echo "latch_approval_proof_exit_code=$LATCH_CODE"
  echo "latch_approval_proof_ok=$SUMMARY_LATCH_OK"
  echo "latch_approval_missing_tests_count=$SUMMARY_LATCH_MISSING_TESTS_COUNT"
  echo "latch_approval_failed_tests_count=$SUMMARY_LATCH_FAILED_TESTS_COUNT"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "idempotency_latch_recommended_action=$RECOMMENDED_ACTION"
  echo "idempotency_latch_summary_file=$SUMMARY_FILE"
  echo "idempotency_latch_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_idempotency_latch_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
