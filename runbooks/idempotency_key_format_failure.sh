#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/idempotency-key-format-${TS_ID}}"
LOG_FILE="$OUT_DIR/idempotency-key-format.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/idempotency-key-format-latest.json"

RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=idempotency_key_format_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  PROOF_OUTPUT="$("$ROOT_DIR/scripts/prove_idempotency_key_format.sh" 2>&1)"
  PROOF_CODE=$?
  set -e
  echo "$PROOF_OUTPUT"

  PROOF_OK="$(extract_value "prove_idempotency_key_format_ok" "$PROOF_OUTPUT")"
  PROOF_REPORT="$(extract_value "prove_idempotency_key_format_latest" "$PROOF_OUTPUT")"
  if [[ -z "$PROOF_REPORT" ]]; then
    PROOF_REPORT="$(extract_value "prove_idempotency_key_format_report" "$PROOF_OUTPUT")"
  fi
  if [[ -z "$PROOF_OK" ]]; then
    if [[ "$PROOF_CODE" -eq 0 ]]; then
      PROOF_OK="true"
    else
      PROOF_OK="false"
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

  RUNBOOK_OK=true
  if [[ "$PROOF_CODE" -ne 0 && "$RUNBOOK_ALLOW_PROOF_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$BUDGET_OK" != "true" && "$RUNBOOK_ALLOW_BUDGET_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi

  SUMMARY_FILE="$OUT_DIR/idempotency-key-format-summary.json"
  python3 - "$SUMMARY_FILE" "$PROOF_REPORT" "$PROOF_CODE" "$BUDGET_OK" "$RUNBOOK_OK" "$RUNBOOK_ALLOW_PROOF_FAIL" "$RUNBOOK_ALLOW_BUDGET_FAIL" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
proof_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
proof_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"
runbook_ok = sys.argv[5].lower() == "true"
allow_proof_fail = sys.argv[6].lower() == "true"
allow_budget_fail = sys.argv[7].lower() == "true"

proof_payload = {}
if proof_report and proof_report.exists():
    with open(proof_report, "r", encoding="utf-8") as f:
        proof_payload = json.load(f)

proof_ok = bool(proof_payload.get("ok", False))
requested_tests_count = len(proof_payload.get("requested_tests", []) or [])
missing_tests_count = len(proof_payload.get("missing_tests", []) or [])
failed_tests_count = len(proof_payload.get("failed_tests", []) or [])

recommended_action = "NO_ACTION"
if proof_exit_code != 0 or not proof_ok:
    recommended_action = "INVESTIGATE_IDEMPOTENCY_KEY_FORMAT_POLICY"
elif not budget_ok:
    recommended_action = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": runbook_ok,
    "allow_proof_fail": allow_proof_fail,
    "allow_budget_fail": allow_budget_fail,
    "proof_report": str(proof_report) if proof_report else None,
    "proof_exit_code": proof_exit_code,
    "proof_ok": proof_ok,
    "requested_tests_count": requested_tests_count,
    "missing_tests_count": missing_tests_count,
    "failed_tests_count": failed_tests_count,
    "budget_ok": budget_ok,
    "recommended_action": recommended_action,
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
  SUMMARY_PROOF_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("proof_ok") else "false")
PY
  )"
  SUMMARY_REQUESTED_TESTS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("requested_tests_count", 0)))
PY
  )"
  SUMMARY_MISSING_TESTS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("missing_tests_count", 0)))
PY
  )"
  SUMMARY_FAILED_TESTS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failed_tests_count", 0)))
PY
  )"

  echo "idempotency_key_format_proof_exit_code=$PROOF_CODE"
  echo "idempotency_key_format_proof_ok=$SUMMARY_PROOF_OK"
  echo "idempotency_key_format_requested_tests_count=$SUMMARY_REQUESTED_TESTS_COUNT"
  echo "idempotency_key_format_missing_tests_count=$SUMMARY_MISSING_TESTS_COUNT"
  echo "idempotency_key_format_failed_tests_count=$SUMMARY_FAILED_TESTS_COUNT"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "idempotency_key_format_recommended_action=$RECOMMENDED_ACTION"
  echo "idempotency_key_format_summary_file=$SUMMARY_FILE"
  echo "idempotency_key_format_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_idempotency_key_format_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
