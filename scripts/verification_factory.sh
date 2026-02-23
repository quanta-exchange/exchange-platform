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
ARCHIVE_MANIFEST=""
if run_step "archive-range" "$ROOT_DIR/scripts/archive_range.sh" --source-file "$ROOT_DIR/build/load/load-smoke.json"; then
  ARCHIVE_MANIFEST="$(extract_value "archive_manifest" "$LOG_DIR/archive-range.log")"
else
  HAS_FAILURE=true
fi
if [[ -n "$ARCHIVE_MANIFEST" ]]; then
  if ! run_step "verify-archive" "$ROOT_DIR/scripts/verify_archive.sh" --manifest "$ARCHIVE_MANIFEST"; then
    HAS_FAILURE=true
  fi
else
  HAS_FAILURE=true
fi
if ! run_step "external-replay-demo" "$ROOT_DIR/tools/external-replay/external_replay_demo.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "controls-check" "$ROOT_DIR/scripts/controls_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-idempotency" "$ROOT_DIR/scripts/prove_idempotency_scope.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-latch-approval" "$ROOT_DIR/scripts/prove_latch_approval.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "model-check" "$ROOT_DIR/scripts/model_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-breakers" "$ROOT_DIR/scripts/prove_breakers.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "verify-service-modes" "$ROOT_DIR/scripts/verify_service_modes.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "ws-resume-smoke" "$ROOT_DIR/scripts/ws_resume_smoke.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "shadow-verify" "$ROOT_DIR/scripts/shadow_verify.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "compliance-evidence" "$ROOT_DIR/scripts/compliance_evidence.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "transparency-report" "$ROOT_DIR/scripts/transparency_report.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "access-review" "$ROOT_DIR/scripts/access_review.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "safety-budget" "$ROOT_DIR/scripts/safety_budget_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "assurance-pack" "$ROOT_DIR/scripts/assurance_pack.sh"; then
  HAS_FAILURE=true
fi

SAFETY_LOG="$LOG_DIR/safety-case.log"
ARCHIVE_LOG="$LOG_DIR/archive-range.log"
VERIFY_ARCHIVE_LOG="$LOG_DIR/verify-archive.log"
EXTERNAL_REPLAY_LOG="$LOG_DIR/external-replay-demo.log"
CONTROLS_LOG="$LOG_DIR/controls-check.log"
PROVE_IDEMPOTENCY_LOG="$LOG_DIR/prove-idempotency.log"
PROVE_LATCH_APPROVAL_LOG="$LOG_DIR/prove-latch-approval.log"
MODEL_CHECK_LOG="$LOG_DIR/model-check.log"
PROVE_BREAKERS_LOG="$LOG_DIR/prove-breakers.log"
VERIFY_SERVICE_MODES_LOG="$LOG_DIR/verify-service-modes.log"
WS_RESUME_SMOKE_LOG="$LOG_DIR/ws-resume-smoke.log"
SHADOW_VERIFY_LOG="$LOG_DIR/shadow-verify.log"
COMPLIANCE_LOG="$LOG_DIR/compliance-evidence.log"
TRANSPARENCY_LOG="$LOG_DIR/transparency-report.log"
ACCESS_REVIEW_LOG="$LOG_DIR/access-review.log"
SAFETY_BUDGET_LOG="$LOG_DIR/safety-budget.log"
ASSURANCE_LOG="$LOG_DIR/assurance-pack.log"

SAFETY_MANIFEST="$(extract_value "safety_case_manifest" "$SAFETY_LOG")"
SAFETY_ARTIFACT="$(extract_value "safety_case_artifact" "$SAFETY_LOG")"
ARCHIVE_RANGE_MANIFEST="$(extract_value "archive_manifest" "$ARCHIVE_LOG")"
VERIFY_ARCHIVE_SHA="$(extract_value "verify_archive_sha256" "$VERIFY_ARCHIVE_LOG")"
EXTERNAL_REPLAY_REPORT="$(extract_value "external_replay_demo_report" "$EXTERNAL_REPLAY_LOG")"
CONTROLS_REPORT="$(extract_value "controls_check_report" "$CONTROLS_LOG")"
PROVE_IDEMPOTENCY_REPORT="$(extract_value "prove_idempotency_report" "$PROVE_IDEMPOTENCY_LOG")"
PROVE_LATCH_APPROVAL_REPORT="$(extract_value "prove_latch_approval_report" "$PROVE_LATCH_APPROVAL_LOG")"
MODEL_CHECK_REPORT="$(extract_value "model_check_report" "$MODEL_CHECK_LOG")"
PROVE_BREAKERS_REPORT="$(extract_value "prove_breakers_report" "$PROVE_BREAKERS_LOG")"
VERIFY_SERVICE_MODES_REPORT="$(extract_value "verify_service_modes_report" "$VERIFY_SERVICE_MODES_LOG")"
WS_RESUME_SMOKE_REPORT="$(extract_value "ws_resume_smoke_report" "$WS_RESUME_SMOKE_LOG")"
SHADOW_VERIFY_REPORT="$(extract_value "shadow_verify_report" "$SHADOW_VERIFY_LOG")"
COMPLIANCE_REPORT="$(extract_value "compliance_evidence_report" "$COMPLIANCE_LOG")"
TRANSPARENCY_REPORT="$(extract_value "transparency_report_file" "$TRANSPARENCY_LOG")"
ACCESS_REVIEW_REPORT="$(extract_value "access_review_report" "$ACCESS_REVIEW_LOG")"
SAFETY_BUDGET_REPORT="$(extract_value "safety_budget_report" "$SAFETY_BUDGET_LOG")"
ASSURANCE_JSON="$(extract_value "assurance_pack_json" "$ASSURANCE_LOG")"

python3 - "$SUMMARY_JSON" "$TS_ID" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$STEPS_TSV" "$SAFETY_MANIFEST" "$SAFETY_ARTIFACT" "$ARCHIVE_RANGE_MANIFEST" "$VERIFY_ARCHIVE_SHA" "$EXTERNAL_REPLAY_REPORT" "$CONTROLS_REPORT" "$PROVE_IDEMPOTENCY_REPORT" "$PROVE_LATCH_APPROVAL_REPORT" "$MODEL_CHECK_REPORT" "$PROVE_BREAKERS_REPORT" "$VERIFY_SERVICE_MODES_REPORT" "$WS_RESUME_SMOKE_REPORT" "$SHADOW_VERIFY_REPORT" "$COMPLIANCE_REPORT" "$TRANSPARENCY_REPORT" "$ACCESS_REVIEW_REPORT" "$SAFETY_BUDGET_REPORT" "$ASSURANCE_JSON" <<'PY'
import json
import sys

summary_path = sys.argv[1]
run_id = sys.argv[2]
run_checks = sys.argv[3].lower() == "true"
run_extended_checks = sys.argv[4].lower() == "true"
steps_tsv = sys.argv[5]
safety_manifest = sys.argv[6]
safety_artifact = sys.argv[7]
archive_manifest = sys.argv[8]
archive_sha = sys.argv[9]
external_replay_report = sys.argv[10]
controls_report = sys.argv[11]
prove_idempotency_report = sys.argv[12]
prove_latch_approval_report = sys.argv[13]
model_check_report = sys.argv[14]
prove_breakers_report = sys.argv[15]
verify_service_modes_report = sys.argv[16]
ws_resume_smoke_report = sys.argv[17]
shadow_verify_report = sys.argv[18]
compliance_report = sys.argv[19]
transparency_report = sys.argv[20]
access_review_report = sys.argv[21]
safety_budget_report = sys.argv[22]
assurance_json = sys.argv[23]

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
        "archive_manifest": archive_manifest or None,
        "archive_sha256": archive_sha or None,
        "external_replay_report": external_replay_report or None,
        "controls_check_report": controls_report or None,
        "prove_idempotency_report": prove_idempotency_report or None,
        "prove_latch_approval_report": prove_latch_approval_report or None,
        "model_check_report": model_check_report or None,
        "prove_breakers_report": prove_breakers_report or None,
        "verify_service_modes_report": verify_service_modes_report or None,
        "ws_resume_smoke_report": ws_resume_smoke_report or None,
        "shadow_verify_report": shadow_verify_report or None,
        "compliance_evidence_report": compliance_report or None,
        "transparency_report": transparency_report or None,
        "access_review_report": access_review_report or None,
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
