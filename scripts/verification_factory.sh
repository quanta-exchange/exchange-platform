#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/verification"
RUN_CHECKS=false
RUN_EXTENDED_CHECKS=false
RUN_LOAD_PROFILES=false
RUN_STARTUP_GUARDRAILS=false
RUN_CHANGE_WORKFLOW=false
RUN_ADVERSARIAL=false
RUN_POLICY_SIGNATURE=false

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
    --run-load-profiles)
      RUN_LOAD_PROFILES=true
      shift
      ;;
    --run-startup-guardrails)
      RUN_STARTUP_GUARDRAILS=true
      shift
      ;;
    --run-change-workflow)
      RUN_CHANGE_WORKFLOW=true
      shift
      ;;
    --run-adversarial)
      RUN_ADVERSARIAL=true
      shift
      ;;
    --run-policy-signature)
      RUN_POLICY_SIGNATURE=true
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
if [[ "$RUN_LOAD_PROFILES" == "true" ]]; then
  if ! run_step "load-all" "$ROOT_DIR/scripts/load_all.sh"; then
    HAS_FAILURE=true
  fi
fi
if [[ "$RUN_STARTUP_GUARDRAILS" == "true" ]]; then
  STARTUP_ALLOW_CORE_FAIL="${VERIFICATION_STARTUP_ALLOW_CORE_FAIL:-true}"
  if ! run_step "runbook-startup-guardrails" env RUNBOOK_ALLOW_CORE_FAIL="$STARTUP_ALLOW_CORE_FAIL" "$ROOT_DIR/runbooks/startup_guardrails.sh"; then
    HAS_FAILURE=true
  fi
fi
if [[ "$RUN_CHANGE_WORKFLOW" == "true" ]]; then
  if ! run_step "runbook-change-workflow" "$ROOT_DIR/runbooks/change_workflow.sh"; then
    HAS_FAILURE=true
  fi
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
if ! run_step "policy-smoke" "$ROOT_DIR/scripts/policy_smoke.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-controls-freshness" "$ROOT_DIR/scripts/prove_controls_freshness.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "controls-check" "$ROOT_DIR/scripts/controls_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "rbac-sod-check" "$ROOT_DIR/scripts/rbac_sod_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "verify-audit-chain" "$ROOT_DIR/scripts/verify_audit_chain.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "verify-change-audit-chain" "$ROOT_DIR/scripts/verify_change_audit_chain.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "pii-log-scan" "$ROOT_DIR/scripts/pii_log_scan.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "anomaly-detector" "$ROOT_DIR/scripts/anomaly_detector.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "anomaly-smoke" "$ROOT_DIR/scripts/anomaly_detector_smoke.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-idempotency" "$ROOT_DIR/scripts/prove_idempotency_scope.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-latch-approval" "$ROOT_DIR/scripts/prove_latch_approval.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-budget-freshness" "$ROOT_DIR/scripts/prove_budget_freshness.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "model-check" "$ROOT_DIR/scripts/model_check.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-breakers" "$ROOT_DIR/scripts/prove_breakers.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "prove-candles" "$ROOT_DIR/scripts/prove_candles.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "snapshot-verify" "$ROOT_DIR/scripts/snapshot_verify.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "verify-service-modes" "$ROOT_DIR/scripts/verify_service_modes.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "ws-resume-smoke" "$ROOT_DIR/scripts/ws_resume_smoke.sh"; then
  HAS_FAILURE=true
fi
if ! run_step "adversarial-tests" "$ROOT_DIR/scripts/adversarial_tests.sh"; then
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
if ! run_step "runbook-budget-failure" "$ROOT_DIR/runbooks/budget_failure.sh"; then
  HAS_FAILURE=true
fi
if [[ "$RUN_POLICY_SIGNATURE" == "true" ]]; then
  if ! run_step "runbook-policy-signature" env RUNBOOK_ALLOW_BUDGET_FAIL=true "$ROOT_DIR/runbooks/policy_signature.sh"; then
    HAS_FAILURE=true
  fi
fi
if [[ "$RUN_ADVERSARIAL" == "true" ]]; then
  if ! run_step "runbook-adversarial-reliability" env RUNBOOK_ALLOW_BUDGET_FAIL=true "$ROOT_DIR/runbooks/adversarial_reliability.sh"; then
    HAS_FAILURE=true
  fi
fi
if ! run_step "assurance-pack" "$ROOT_DIR/scripts/assurance_pack.sh"; then
  HAS_FAILURE=true
fi

SAFETY_LOG="$LOG_DIR/safety-case.log"
LOAD_ALL_LOG="$LOG_DIR/load-all.log"
STARTUP_GUARDRAILS_LOG="$LOG_DIR/runbook-startup-guardrails.log"
CHANGE_WORKFLOW_LOG="$LOG_DIR/runbook-change-workflow.log"
ARCHIVE_LOG="$LOG_DIR/archive-range.log"
VERIFY_ARCHIVE_LOG="$LOG_DIR/verify-archive.log"
EXTERNAL_REPLAY_LOG="$LOG_DIR/external-replay-demo.log"
POLICY_SMOKE_LOG="$LOG_DIR/policy-smoke.log"
CONTROLS_LOG="$LOG_DIR/controls-check.log"
PROVE_CONTROLS_FRESHNESS_LOG="$LOG_DIR/prove-controls-freshness.log"
RBAC_SOD_LOG="$LOG_DIR/rbac-sod-check.log"
VERIFY_AUDIT_CHAIN_LOG="$LOG_DIR/verify-audit-chain.log"
VERIFY_CHANGE_AUDIT_CHAIN_LOG="$LOG_DIR/verify-change-audit-chain.log"
PII_LOG_SCAN_LOG="$LOG_DIR/pii-log-scan.log"
ANOMALY_DETECTOR_LOG="$LOG_DIR/anomaly-detector.log"
ANOMALY_SMOKE_LOG="$LOG_DIR/anomaly-smoke.log"
PROVE_IDEMPOTENCY_LOG="$LOG_DIR/prove-idempotency.log"
PROVE_LATCH_APPROVAL_LOG="$LOG_DIR/prove-latch-approval.log"
PROVE_BUDGET_FRESHNESS_LOG="$LOG_DIR/prove-budget-freshness.log"
MODEL_CHECK_LOG="$LOG_DIR/model-check.log"
PROVE_BREAKERS_LOG="$LOG_DIR/prove-breakers.log"
PROVE_CANDLES_LOG="$LOG_DIR/prove-candles.log"
SNAPSHOT_VERIFY_LOG="$LOG_DIR/snapshot-verify.log"
VERIFY_SERVICE_MODES_LOG="$LOG_DIR/verify-service-modes.log"
WS_RESUME_SMOKE_LOG="$LOG_DIR/ws-resume-smoke.log"
ADVERSARIAL_TESTS_LOG="$LOG_DIR/adversarial-tests.log"
SHADOW_VERIFY_LOG="$LOG_DIR/shadow-verify.log"
COMPLIANCE_LOG="$LOG_DIR/compliance-evidence.log"
TRANSPARENCY_LOG="$LOG_DIR/transparency-report.log"
ACCESS_REVIEW_LOG="$LOG_DIR/access-review.log"
SAFETY_BUDGET_LOG="$LOG_DIR/safety-budget.log"
BUDGET_FAILURE_RUNBOOK_LOG="$LOG_DIR/runbook-budget-failure.log"
POLICY_SIGNATURE_RUNBOOK_LOG="$LOG_DIR/runbook-policy-signature.log"
ADVERSARIAL_RUNBOOK_LOG="$LOG_DIR/runbook-adversarial-reliability.log"
ASSURANCE_LOG="$LOG_DIR/assurance-pack.log"

SAFETY_MANIFEST="$(extract_value "safety_case_manifest" "$SAFETY_LOG")"
SAFETY_ARTIFACT="$(extract_value "safety_case_artifact" "$SAFETY_LOG")"
LOAD_ALL_REPORT="$(extract_value "load_all_report" "$LOAD_ALL_LOG")"
STARTUP_GUARDRAILS_RUNBOOK_DIR="$(extract_value "runbook_output_dir" "$STARTUP_GUARDRAILS_LOG")"
CHANGE_WORKFLOW_RUNBOOK_DIR="$(extract_value "runbook_output_dir" "$CHANGE_WORKFLOW_LOG")"
ARCHIVE_RANGE_MANIFEST="$(extract_value "archive_manifest" "$ARCHIVE_LOG")"
VERIFY_ARCHIVE_SHA="$(extract_value "verify_archive_sha256" "$VERIFY_ARCHIVE_LOG")"
EXTERNAL_REPLAY_REPORT="$(extract_value "external_replay_demo_report" "$EXTERNAL_REPLAY_LOG")"
POLICY_SMOKE_REPORT="$(extract_value "policy_smoke_latest" "$POLICY_SMOKE_LOG")"
CONTROLS_REPORT="$(extract_value "controls_check_report" "$CONTROLS_LOG")"
PROVE_CONTROLS_FRESHNESS_REPORT="$(extract_value "prove_controls_freshness_report" "$PROVE_CONTROLS_FRESHNESS_LOG")"
RBAC_SOD_REPORT="$(extract_value "rbac_sod_check_report" "$RBAC_SOD_LOG")"
VERIFY_AUDIT_CHAIN_REPORT="$(extract_value "verify_audit_chain_report" "$VERIFY_AUDIT_CHAIN_LOG")"
VERIFY_CHANGE_AUDIT_CHAIN_REPORT="$(extract_value "verify_change_audit_chain_report" "$VERIFY_CHANGE_AUDIT_CHAIN_LOG")"
PII_LOG_SCAN_REPORT="$(extract_value "pii_log_scan_report" "$PII_LOG_SCAN_LOG")"
ANOMALY_DETECTOR_REPORT="$(extract_value "anomaly_report" "$ANOMALY_DETECTOR_LOG")"
ANOMALY_SMOKE_REPORT="$(extract_value "anomaly_smoke_report" "$ANOMALY_SMOKE_LOG")"
PROVE_IDEMPOTENCY_REPORT="$(extract_value "prove_idempotency_report" "$PROVE_IDEMPOTENCY_LOG")"
PROVE_LATCH_APPROVAL_REPORT="$(extract_value "prove_latch_approval_report" "$PROVE_LATCH_APPROVAL_LOG")"
PROVE_BUDGET_FRESHNESS_REPORT="$(extract_value "prove_budget_freshness_report" "$PROVE_BUDGET_FRESHNESS_LOG")"
MODEL_CHECK_REPORT="$(extract_value "model_check_report" "$MODEL_CHECK_LOG")"
PROVE_BREAKERS_REPORT="$(extract_value "prove_breakers_report" "$PROVE_BREAKERS_LOG")"
PROVE_CANDLES_REPORT="$(extract_value "prove_candles_report" "$PROVE_CANDLES_LOG")"
SNAPSHOT_VERIFY_REPORT="$(extract_value "snapshot_verify_report" "$SNAPSHOT_VERIFY_LOG")"
VERIFY_SERVICE_MODES_REPORT="$(extract_value "verify_service_modes_report" "$VERIFY_SERVICE_MODES_LOG")"
WS_RESUME_SMOKE_REPORT="$(extract_value "ws_resume_smoke_report" "$WS_RESUME_SMOKE_LOG")"
ADVERSARIAL_TESTS_REPORT="$(extract_value "adversarial_tests_latest" "$ADVERSARIAL_TESTS_LOG")"
SHADOW_VERIFY_REPORT="$(extract_value "shadow_verify_report" "$SHADOW_VERIFY_LOG")"
COMPLIANCE_REPORT="$(extract_value "compliance_evidence_report" "$COMPLIANCE_LOG")"
TRANSPARENCY_REPORT="$(extract_value "transparency_report_file" "$TRANSPARENCY_LOG")"
ACCESS_REVIEW_REPORT="$(extract_value "access_review_report" "$ACCESS_REVIEW_LOG")"
SAFETY_BUDGET_REPORT="$(extract_value "safety_budget_report" "$SAFETY_BUDGET_LOG")"
BUDGET_FAILURE_RUNBOOK_DIR="$(extract_value "runbook_output_dir" "$BUDGET_FAILURE_RUNBOOK_LOG")"
POLICY_SIGNATURE_RUNBOOK_DIR="$(extract_value "runbook_output_dir" "$POLICY_SIGNATURE_RUNBOOK_LOG")"
ADVERSARIAL_RUNBOOK_DIR="$(extract_value "runbook_output_dir" "$ADVERSARIAL_RUNBOOK_LOG")"
ASSURANCE_JSON="$(extract_value "assurance_pack_json" "$ASSURANCE_LOG")"

python3 - "$SUMMARY_JSON" "$TS_ID" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$RUN_LOAD_PROFILES" "$STEPS_TSV" "$SAFETY_MANIFEST" "$SAFETY_ARTIFACT" "$LOAD_ALL_REPORT" "$ARCHIVE_RANGE_MANIFEST" "$VERIFY_ARCHIVE_SHA" "$EXTERNAL_REPLAY_REPORT" "$POLICY_SMOKE_REPORT" "$CONTROLS_REPORT" "$PROVE_CONTROLS_FRESHNESS_REPORT" "$PROVE_IDEMPOTENCY_REPORT" "$PROVE_LATCH_APPROVAL_REPORT" "$PROVE_BUDGET_FRESHNESS_REPORT" "$MODEL_CHECK_REPORT" "$PROVE_BREAKERS_REPORT" "$PROVE_CANDLES_REPORT" "$SNAPSHOT_VERIFY_REPORT" "$VERIFY_SERVICE_MODES_REPORT" "$WS_RESUME_SMOKE_REPORT" "$ADVERSARIAL_TESTS_REPORT" "$SHADOW_VERIFY_REPORT" "$COMPLIANCE_REPORT" "$TRANSPARENCY_REPORT" "$ACCESS_REVIEW_REPORT" "$SAFETY_BUDGET_REPORT" "$ASSURANCE_JSON" "$RUN_STARTUP_GUARDRAILS" "$STARTUP_GUARDRAILS_RUNBOOK_DIR" "$RUN_CHANGE_WORKFLOW" "$CHANGE_WORKFLOW_RUNBOOK_DIR" "$BUDGET_FAILURE_RUNBOOK_DIR" "$RUN_POLICY_SIGNATURE" "$POLICY_SIGNATURE_RUNBOOK_DIR" "$RUN_ADVERSARIAL" "$ADVERSARIAL_RUNBOOK_DIR" "$VERIFY_AUDIT_CHAIN_REPORT" "$VERIFY_CHANGE_AUDIT_CHAIN_REPORT" "$PII_LOG_SCAN_REPORT" "$ANOMALY_DETECTOR_REPORT" "$ANOMALY_SMOKE_REPORT" "$RBAC_SOD_REPORT" <<'PY'
import json
import sys

summary_path = sys.argv[1]
run_id = sys.argv[2]
run_checks = sys.argv[3].lower() == "true"
run_extended_checks = sys.argv[4].lower() == "true"
run_load_profiles = sys.argv[5].lower() == "true"
steps_tsv = sys.argv[6]
safety_manifest = sys.argv[7]
safety_artifact = sys.argv[8]
load_all_report = sys.argv[9]
archive_manifest = sys.argv[10]
archive_sha = sys.argv[11]
external_replay_report = sys.argv[12]
policy_smoke_report = sys.argv[13]
controls_report = sys.argv[14]
prove_controls_freshness_report = sys.argv[15]
prove_idempotency_report = sys.argv[16]
prove_latch_approval_report = sys.argv[17]
prove_budget_freshness_report = sys.argv[18]
model_check_report = sys.argv[19]
prove_breakers_report = sys.argv[20]
prove_candles_report = sys.argv[21]
snapshot_verify_report = sys.argv[22]
verify_service_modes_report = sys.argv[23]
ws_resume_smoke_report = sys.argv[24]
adversarial_tests_report = sys.argv[25]
shadow_verify_report = sys.argv[26]
compliance_report = sys.argv[27]
transparency_report = sys.argv[28]
access_review_report = sys.argv[29]
safety_budget_report = sys.argv[30]
assurance_json = sys.argv[31]
run_startup_guardrails = sys.argv[32].lower() == "true"
startup_guardrails_runbook_dir = sys.argv[33]
run_change_workflow = sys.argv[34].lower() == "true"
change_workflow_runbook_dir = sys.argv[35]
budget_failure_runbook_dir = sys.argv[36]
run_policy_signature = sys.argv[37].lower() == "true"
policy_signature_runbook_dir = sys.argv[38]
run_adversarial = sys.argv[39].lower() == "true"
adversarial_runbook_dir = sys.argv[40]
verify_audit_chain_report = sys.argv[41]
verify_change_audit_chain_report = sys.argv[42]
pii_log_scan_report = sys.argv[43]
anomaly_detector_report = sys.argv[44]
anomaly_smoke_report = sys.argv[45]
rbac_sod_report = sys.argv[46]

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
    "run_load_profiles": run_load_profiles,
    "run_startup_guardrails": run_startup_guardrails,
    "run_change_workflow": run_change_workflow,
    "run_policy_signature": run_policy_signature,
    "run_adversarial": run_adversarial,
    "steps": steps,
    "artifacts": {
        "safety_case_manifest": safety_manifest or None,
        "safety_case_artifact": safety_artifact or None,
        "load_all_report": load_all_report or None,
        "startup_guardrails_runbook_dir": startup_guardrails_runbook_dir or None,
        "change_workflow_runbook_dir": change_workflow_runbook_dir or None,
        "budget_failure_runbook_dir": budget_failure_runbook_dir or None,
        "policy_signature_runbook_dir": policy_signature_runbook_dir or None,
        "adversarial_runbook_dir": adversarial_runbook_dir or None,
        "archive_manifest": archive_manifest or None,
        "archive_sha256": archive_sha or None,
        "external_replay_report": external_replay_report or None,
        "policy_smoke_report": policy_smoke_report or None,
        "controls_check_report": controls_report or None,
        "prove_controls_freshness_report": prove_controls_freshness_report or None,
        "verify_audit_chain_report": verify_audit_chain_report or None,
        "verify_change_audit_chain_report": verify_change_audit_chain_report or None,
        "pii_log_scan_report": pii_log_scan_report or None,
        "anomaly_detector_report": anomaly_detector_report or None,
        "anomaly_smoke_report": anomaly_smoke_report or None,
        "rbac_sod_check_report": rbac_sod_report or None,
        "prove_idempotency_report": prove_idempotency_report or None,
        "prove_latch_approval_report": prove_latch_approval_report or None,
        "prove_budget_freshness_report": prove_budget_freshness_report or None,
        "model_check_report": model_check_report or None,
        "prove_breakers_report": prove_breakers_report or None,
        "prove_candles_report": prove_candles_report or None,
        "snapshot_verify_report": snapshot_verify_report or None,
        "verify_service_modes_report": verify_service_modes_report or None,
        "ws_resume_smoke_report": ws_resume_smoke_report or None,
        "adversarial_tests_report": adversarial_tests_report or None,
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
