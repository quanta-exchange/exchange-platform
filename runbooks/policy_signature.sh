#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/policy-signature-${TS_ID}}"
LOG_FILE="$OUT_DIR/policy-signature.log"

RUNBOOK_ALLOW_POLICY_FAIL="${RUNBOOK_ALLOW_POLICY_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=policy_signature"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  POLICY_OUTPUT="$(
    OUT_DIR="$OUT_DIR/policy-smoke" "$ROOT_DIR/scripts/policy_smoke.sh" 2>&1
  )"
  POLICY_CODE=$?
  set -e
  echo "$POLICY_OUTPUT"

  POLICY_OK="$(extract_value "policy_smoke_ok" "$POLICY_OUTPUT")"
  POLICY_REPORT="$(extract_value "policy_smoke_latest" "$POLICY_OUTPUT")"
  if [[ -z "$POLICY_REPORT" ]]; then
    POLICY_REPORT="$OUT_DIR/policy-smoke/policy-smoke-latest.json"
  fi
  if [[ -z "$POLICY_OK" ]]; then
    if [[ "$POLICY_CODE" -eq 0 ]]; then
      POLICY_OK="true"
    else
      POLICY_OK="false"
    fi
  fi

  echo "policy_smoke_exit_code=$POLICY_CODE"
  echo "policy_smoke_ok=$POLICY_OK"
  echo "policy_smoke_latest=$POLICY_REPORT"

  BUDGET_OK="false"
  if "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"; then
    BUDGET_OK="true"
    echo "runbook_budget_ok=true"
  else
    BUDGET_OK="false"
    echo "runbook_budget_ok=false"
  fi

  SUMMARY_FILE="$OUT_DIR/policy-signature-summary.json"
  python3 - "$SUMMARY_FILE" "$POLICY_REPORT" "$POLICY_CODE" "$BUDGET_OK" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
policy_report = pathlib.Path(sys.argv[2]).resolve()
policy_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"

payload = {}
if policy_report.exists():
    with open(policy_report, "r", encoding="utf-8") as f:
        payload = json.load(f)

policy_ok = bool(payload.get("ok", False)) if payload else False

recommendation = "NO_ACTION"
if policy_exit_code != 0 or not policy_ok:
    recommendation = "REGENERATE_AND_VERIFY_POLICY_SIGNATURE"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "policy_report": str(policy_report),
    "policy_exit_code": policy_exit_code,
    "policy_ok": policy_ok,
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

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  RUNBOOK_OK=true
  if [[ "$POLICY_CODE" -ne 0 && "$RUNBOOK_ALLOW_POLICY_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$BUDGET_OK" != "true" && "$RUNBOOK_ALLOW_BUDGET_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi

  echo "policy_recommended_action=$RECOMMENDED_ACTION"
  echo "runbook_policy_signature_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
