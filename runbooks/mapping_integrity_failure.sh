#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/mapping-integrity-${TS_ID}}"
LOG_FILE="$OUT_DIR/mapping-integrity.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/mapping-integrity-latest.json"

RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=mapping_integrity_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  PROOF_OUTPUT="$("$ROOT_DIR/scripts/prove_mapping_integrity.sh" 2>&1)"
  PROOF_CODE=$?
  set -e
  echo "$PROOF_OUTPUT"

  PROOF_OK="$(extract_value "prove_mapping_integrity_ok" "$PROOF_OUTPUT")"
  PROOF_REPORT="$(extract_value "prove_mapping_integrity_latest" "$PROOF_OUTPUT")"
  if [[ -z "$PROOF_REPORT" ]]; then
    PROOF_REPORT="$(extract_value "prove_mapping_integrity_report" "$PROOF_OUTPUT")"
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

  SUMMARY_FILE="$OUT_DIR/mapping-integrity-summary.json"
  python3 - "$SUMMARY_FILE" "$PROOF_REPORT" "$PROOF_CODE" "$BUDGET_OK" "$RUNBOOK_ALLOW_PROOF_FAIL" "$RUNBOOK_ALLOW_BUDGET_FAIL" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
proof_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
proof_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"
allow_proof_fail = sys.argv[5].lower() == "true"
allow_budget_fail = sys.argv[6].lower() == "true"

proof_payload = {}
if proof_report and proof_report.exists():
    with open(proof_report, "r", encoding="utf-8") as f:
        proof_payload = json.load(f)

proof_ok = bool(proof_payload.get("ok", False)) if proof_payload else False
duplicate_probe = proof_payload.get("duplicate_probe", {}) if isinstance(proof_payload, dict) else {}
baseline_probe = proof_payload.get("baseline_probe", {}) if isinstance(proof_payload, dict) else {}
duplicate_probe_exit_code = int(duplicate_probe.get("exit_code", 0) or 0)
duplicate_mapping_ids_count = int(
    duplicate_probe.get("duplicate_mapping_ids_count", 0) or 0
)
baseline_probe_exit_code = int(baseline_probe.get("exit_code", 0) or 0)
baseline_duplicate_mapping_ids_count = int(
    baseline_probe.get("duplicate_mapping_ids_count", 0) or 0
)

recommendation = "NO_ACTION"
if proof_exit_code != 0 or not proof_ok:
    if duplicate_probe_exit_code == 0:
        recommendation = "INVESTIGATE_DUPLICATE_MAPPING_GUARD"
    elif baseline_probe_exit_code != 0:
        recommendation = "INVESTIGATE_BASELINE_MAPPING"
    else:
        recommendation = "INVESTIGATE_MAPPING_INTEGRITY_PROOF"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

runbook_ok = (
    ((proof_exit_code == 0) and proof_ok) or allow_proof_fail
) and (budget_ok or allow_budget_fail)

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": runbook_ok,
    "allow_proof_fail": allow_proof_fail,
    "allow_budget_fail": allow_budget_fail,
    "proof_report": str(proof_report) if proof_report else None,
    "proof_exit_code": proof_exit_code,
    "proof_ok": proof_ok,
    "duplicate_probe_exit_code": duplicate_probe_exit_code,
    "duplicate_mapping_ids_count": duplicate_mapping_ids_count,
    "baseline_probe_exit_code": baseline_probe_exit_code,
    "baseline_duplicate_mapping_ids_count": baseline_duplicate_mapping_ids_count,
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
  SUMMARY_PROOF_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("proof_ok") else "false")
PY
  )"
  SUMMARY_DUPLICATE_PROBE_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("duplicate_probe_exit_code", 0)))
PY
  )"
  SUMMARY_DUPLICATE_MAPPING_IDS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("duplicate_mapping_ids_count", 0)))
PY
  )"
  SUMMARY_BASELINE_PROBE_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("baseline_probe_exit_code", 0)))
PY
  )"
  SUMMARY_BASELINE_DUPLICATE_MAPPING_IDS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("baseline_duplicate_mapping_ids_count", 0)))
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

  echo "mapping_integrity_proof_exit_code=$PROOF_CODE"
  echo "mapping_integrity_proof_ok=$SUMMARY_PROOF_OK"
  echo "mapping_integrity_duplicate_probe_exit_code=$SUMMARY_DUPLICATE_PROBE_EXIT_CODE"
  echo "mapping_integrity_duplicate_mapping_ids_count=$SUMMARY_DUPLICATE_MAPPING_IDS_COUNT"
  echo "mapping_integrity_baseline_probe_exit_code=$SUMMARY_BASELINE_PROBE_EXIT_CODE"
  echo "mapping_integrity_baseline_duplicate_mapping_ids_count=$SUMMARY_BASELINE_DUPLICATE_MAPPING_IDS_COUNT"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "mapping_integrity_recommended_action=$RECOMMENDED_ACTION"
  echo "mapping_integrity_summary_file=$SUMMARY_FILE"
  echo "mapping_integrity_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_mapping_integrity_ok=$SUMMARY_RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$SUMMARY_RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
