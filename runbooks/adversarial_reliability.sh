#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/adversarial-reliability-${TS_ID}}"
LOG_FILE="$OUT_DIR/adversarial-reliability.log"
ADVERSARIAL_OUT_DIR="$OUT_DIR/adversarial"

RUNBOOK_ALLOW_ADVERSARIAL_FAIL="${RUNBOOK_ALLOW_ADVERSARIAL_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=adversarial_reliability"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  ADVERSARIAL_OUTPUT="$(
    OUT_DIR="$ADVERSARIAL_OUT_DIR" "$ROOT_DIR/scripts/adversarial_tests.sh" 2>&1
  )"
  ADVERSARIAL_CODE=$?
  set -e
  echo "$ADVERSARIAL_OUTPUT"

  ADVERSARIAL_OK="$(extract_value "adversarial_tests_ok" "$ADVERSARIAL_OUTPUT")"
  ADVERSARIAL_REPORT="$(extract_value "adversarial_tests_latest" "$ADVERSARIAL_OUTPUT")"
  if [[ -z "$ADVERSARIAL_REPORT" ]]; then
    ADVERSARIAL_REPORT="$ADVERSARIAL_OUT_DIR/adversarial-tests-latest.json"
  fi
  if [[ -z "$ADVERSARIAL_OK" ]]; then
    if [[ "$ADVERSARIAL_CODE" -eq 0 ]]; then
      ADVERSARIAL_OK="true"
    else
      ADVERSARIAL_OK="false"
    fi
  fi

  echo "adversarial_tests_exit_code=$ADVERSARIAL_CODE"
  echo "adversarial_tests_ok=$ADVERSARIAL_OK"
  echo "adversarial_tests_latest=$ADVERSARIAL_REPORT"

  BUDGET_OK="false"
  if "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"; then
    BUDGET_OK="true"
    echo "runbook_budget_ok=true"
  else
    BUDGET_OK="false"
    echo "runbook_budget_ok=false"
  fi

  SUMMARY_FILE="$OUT_DIR/adversarial-reliability-summary.json"
  python3 - "$SUMMARY_FILE" "$ADVERSARIAL_REPORT" "$ADVERSARIAL_CODE" "$BUDGET_OK" "$RUNBOOK_ALLOW_ADVERSARIAL_FAIL" "$RUNBOOK_ALLOW_BUDGET_FAIL" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
adversarial_report = pathlib.Path(sys.argv[2]).resolve()
adversarial_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"
allow_adversarial_fail = sys.argv[5].lower() == "true"
allow_budget_fail = sys.argv[6].lower() == "true"

payload = {}
if adversarial_report.exists():
    with open(adversarial_report, "r", encoding="utf-8") as f:
        payload = json.load(f)

steps = payload.get("steps", []) if isinstance(payload, dict) else []
failed_steps = [str(step.get("name")) for step in steps if step.get("status") == "fail"]
skipped_steps = [str(step.get("name")) for step in steps if step.get("status") == "skip"]
exactly_once_status = None
for step in steps:
    if step.get("name") == "exactly_once_stress":
        exactly_once_status = step.get("status")
        break

recommendation = "NO_ACTION"
if adversarial_exit_code != 0:
    if any(name in {"ws_smoke", "ws_resume_smoke"} for name in failed_steps):
        recommendation = "CHECK_WS_BACKPRESSURE_AND_RESUME_POLICY"
    elif "policy_smoke" in failed_steps:
        recommendation = "VERIFY_POLICY_SIGNATURE_AND_RUNTIME_LOAD"
    elif "snapshot_verify" in failed_steps:
        recommendation = "RUN_SNAPSHOT_VERIFY_AND_RESTORE_DRILL"
    elif "exactly_once_stress" in failed_steps:
        recommendation = "CHECK_LEDGER_IDEMPOTENCY_AND_CONSUMER_RESUME"
    else:
        recommendation = "INVESTIGATE_ADVERSARIAL_FAILURE"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

adversarial_ok = bool(payload.get("ok", False)) if payload else False
runbook_ok = (
    ((adversarial_exit_code == 0) and adversarial_ok) or allow_adversarial_fail
) and (budget_ok or allow_budget_fail)

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": runbook_ok,
    "allow_adversarial_fail": allow_adversarial_fail,
    "allow_budget_fail": allow_budget_fail,
    "adversarial_report": str(adversarial_report),
    "adversarial_exit_code": adversarial_exit_code,
    "adversarial_ok": adversarial_ok,
    "failed_steps": failed_steps,
    "failed_step_count": len(failed_steps),
    "skipped_steps": skipped_steps,
    "skipped_step_count": len(skipped_steps),
    "exactly_once_status": exactly_once_status,
    "budget_ok": budget_ok,
    "recommended_action": recommendation,
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  RECOMMENDED_ACTION="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("recommended_action", "UNKNOWN"))
PY
  )"
  FAILED_STEP_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failed_step_count", 0)))
PY
  )"
  SUMMARY_RUNBOOK_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("runbook_ok") else "false")
PY
  )"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  echo "adversarial_failed_step_count=$FAILED_STEP_COUNT"
  echo "adversarial_recommended_action=$RECOMMENDED_ACTION"
  echo "runbook_adversarial_reliability_ok=$SUMMARY_RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$SUMMARY_RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
