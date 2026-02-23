#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/verification"
RUN_CHECKS=false
RUN_EXTENDED_CHECKS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --run-checks)
      RUN_CHECKS=true
      shift
      ;;
    --run-extended-checks)
      RUN_EXTENDED_CHECKS=true
      shift
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/$TS_ID"
LOG_DIR="$RUN_DIR/logs"
STEPS_TSV="$RUN_DIR/steps.tsv"
SUMMARY_JSON="$RUN_DIR/verification-summary.json"
mkdir -p "$LOG_DIR"
: >"$STEPS_TSV"

relpath() {
  python3 - "$1" "$2" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

run_step() {
  local name="$1"
  shift
  local logfile="$LOG_DIR/${name}.log"
  echo "running_step=${name}"
  set +e
  "$@" >"$logfile" 2>&1
  local code=$?
  set -e
  if [[ "$code" -eq 0 ]]; then
    echo "step_result=${name}:pass"
    echo "${name}	pass	${code}	$(relpath "$ROOT_DIR" "$logfile")" >>"$STEPS_TSV"
    return 0
  fi
  echo "step_result=${name}:fail"
  echo "${name}	fail	${code}	$(relpath "$ROOT_DIR" "$logfile")" >>"$STEPS_TSV"
  return 1
}

extract_value() {
  local key="$1"
  local logfile="$2"
  if [[ ! -f "$logfile" ]]; then
    return 0
  fi
  grep -E "^${key}=" "$logfile" | tail -n 1 | sed "s/^${key}=//"
}

SAFETY_CASE_CMD=("$ROOT_DIR/scripts/safety_case.sh")
if [[ "$RUN_CHECKS" == "true" ]]; then
  SAFETY_CASE_CMD+=("--run-checks")
fi
if [[ "$RUN_EXTENDED_CHECKS" == "true" ]]; then
  SAFETY_CASE_CMD+=("--run-extended-checks")
fi

HAS_FAILURE=false
if ! run_step "safety-case" "${SAFETY_CASE_CMD[@]}"; then
  HAS_FAILURE=true
fi
if ! run_step "controls-check" "$ROOT_DIR/scripts/controls_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "compliance-evidence" "$ROOT_DIR/scripts/compliance_evidence.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "transparency-report" "$ROOT_DIR/scripts/transparency_report.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "safety-budget" "$ROOT_DIR/scripts/safety_budget_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "assurance-pack" "$ROOT_DIR/scripts/assurance_pack.sh"; then
  HAS_FAILURE=true
fi

SAFETY_LOG="$LOG_DIR/safety-case.log"
CONTROLS_LOG="$LOG_DIR/controls-check.log"
COMPLIANCE_LOG="$LOG_DIR/compliance-evidence.log"
TRANSPARENCY_LOG="$LOG_DIR/transparency-report.log"
SAFETY_BUDGET_LOG="$LOG_DIR/safety-budget.log"
ASSURANCE_LOG="$LOG_DIR/assurance-pack.log"

SAFETY_MANIFEST="$(extract_value "safety_case_manifest" "$SAFETY_LOG")"
SAFETY_ARTIFACT="$(extract_value "safety_case_artifact" "$SAFETY_LOG")"
CONTROLS_REPORT="$(extract_value "controls_check_report" "$CONTROLS_LOG")"
COMPLIANCE_REPORT="$(extract_value "compliance_evidence_report" "$COMPLIANCE_LOG")"
TRANSPARENCY_REPORT="$(extract_value "transparency_report_file" "$TRANSPARENCY_LOG")"
SAFETY_BUDGET_REPORT="$(extract_value "safety_budget_report" "$SAFETY_BUDGET_LOG")"
ASSURANCE_JSON="$(extract_value "assurance_pack_json" "$ASSURANCE_LOG")"

python3 - "$SUMMARY_JSON" "$TS_ID" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$STEPS_TSV" "$SAFETY_MANIFEST" "$SAFETY_ARTIFACT" "$CONTROLS_REPORT" "$COMPLIANCE_REPORT" "$TRANSPARENCY_REPORT" "$SAFETY_BUDGET_REPORT" "$ASSURANCE_JSON" <<'PY'
import json
import sys

summary_path = sys.argv[1]
run_id = sys.argv[2]
run_checks = sys.argv[3].lower() == "true"
run_extended_checks = sys.argv[4].lower() == "true"
steps_tsv = sys.argv[5]
safety_manifest = sys.argv[6]
safety_artifact = sys.argv[7]
controls_report = sys.argv[8]
compliance_report = sys.argv[9]
transparency_report = sys.argv[10]
safety_budget_report = sys.argv[11]
assurance_json = sys.argv[12]

steps = []
ok = True
with open(steps_tsv, "r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        name, status, code, log_path = raw.split("\t")
        entry = {
            "name": name,
            "status": status,
            "exit_code": int(code),
            "log": log_path,
        }
        steps.append(entry)
        if status != "pass":
            ok = False

summary = {
    "run_id": run_id,
    "ok": ok,
    "run_checks": run_checks,
    "run_extended_checks": run_extended_checks,
    "steps": steps,
    "artifacts": {
        "safety_case_manifest": safety_manifest or None,
        "safety_case_artifact": safety_artifact or None,
        "controls_check_report": controls_report or None,
        "compliance_evidence_report": compliance_report or None,
        "transparency_report": transparency_report or None,
        "safety_budget_report": safety_budget_report or None,
        "assurance_pack_json": assurance_json or None,
    },
}

with open(summary_path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "verification_summary=${SUMMARY_JSON}"
echo "verification_ok=$([[ "$HAS_FAILURE" == "false" ]] && echo true || echo false)"

if [[ "$HAS_FAILURE" == "true" ]]; then
  exit 1
fi
