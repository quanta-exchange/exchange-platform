#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/release-gate}"
RUN_CHECKS=false
RUN_EXTENDED_CHECKS=false
RUN_LOAD_PROFILES=false
RUN_STARTUP_GUARDRAILS=false
RUN_CHANGE_WORKFLOW=false
RUN_ADVERSARIAL=false
RUN_POLICY_SIGNATURE=false
RUN_POLICY_TAMPER=false
RUN_NETWORK_PARTITION=false
RUN_REDPANDA_BOUNCE=false
RUN_DETERMINISM=false
STRICT_CONTROLS=false

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
    --run-policy-tamper)
      RUN_POLICY_TAMPER=true
      shift
      ;;
    --run-network-partition)
      RUN_NETWORK_PARTITION=true
      shift
      ;;
    --run-redpanda-bounce)
      RUN_REDPANDA_BOUNCE=true
      shift
      ;;
    --run-determinism)
      RUN_DETERMINISM=true
      shift
      ;;
    --strict-controls)
      STRICT_CONTROLS=true
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/release-gate-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/release-gate-latest.json"

VERIFY_CMD=("$ROOT_DIR/scripts/verification_factory.sh")
if [[ "$RUN_CHECKS" == "true" ]]; then
  VERIFY_CMD+=("--run-checks")
fi
if [[ "$RUN_EXTENDED_CHECKS" == "true" ]]; then
  VERIFY_CMD+=("--run-extended-checks")
fi
if [[ "$RUN_LOAD_PROFILES" == "true" ]]; then
  VERIFY_CMD+=("--run-load-profiles")
fi
if [[ "$RUN_STARTUP_GUARDRAILS" == "true" ]]; then
  VERIFY_CMD+=("--run-startup-guardrails")
fi
if [[ "$RUN_CHANGE_WORKFLOW" == "true" ]]; then
  VERIFY_CMD+=("--run-change-workflow")
fi
if [[ "$RUN_ADVERSARIAL" == "true" ]]; then
  VERIFY_CMD+=("--run-adversarial")
fi
if [[ "$RUN_POLICY_SIGNATURE" == "true" ]]; then
  VERIFY_CMD+=("--run-policy-signature")
fi
if [[ "$RUN_POLICY_TAMPER" == "true" ]]; then
  VERIFY_CMD+=("--run-policy-tamper")
fi
if [[ "$RUN_NETWORK_PARTITION" == "true" ]]; then
  VERIFY_CMD+=("--run-network-partition")
fi
if [[ "$RUN_REDPANDA_BOUNCE" == "true" ]]; then
  VERIFY_CMD+=("--run-redpanda-bounce")
fi
if [[ "$RUN_DETERMINISM" == "true" ]]; then
  VERIFY_CMD+=("--run-determinism")
fi

set +e
VERIFY_OUTPUT="$("${VERIFY_CMD[@]}" 2>&1)"
VERIFY_EXIT_CODE=$?
set -e
echo "$VERIFY_OUTPUT"
VERIFY_SUMMARY="$(echo "$VERIFY_OUTPUT" | awk -F= '/^verification_summary=/{print $2}' | tail -n 1)"
VERIFY_OK="$(echo "$VERIFY_OUTPUT" | awk -F= '/^verification_ok=/{print $2}' | tail -n 1)"
if [[ -z "$VERIFY_OK" ]]; then
  if [[ "$VERIFY_EXIT_CODE" -eq 0 ]]; then
    VERIFY_OK=true
  else
    VERIFY_OK=false
  fi
fi

if [[ -z "$VERIFY_SUMMARY" || ! -f "$VERIFY_SUMMARY" ]]; then
  echo "verification summary missing" >&2
  exit 1
fi

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"

python3 - "$REPORT_FILE" "$VERIFY_SUMMARY" "$VERIFY_OK" "$VERIFY_EXIT_CODE" "$COMMIT" "$BRANCH" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$RUN_LOAD_PROFILES" "$RUN_STARTUP_GUARDRAILS" "$RUN_CHANGE_WORKFLOW" "$RUN_ADVERSARIAL" "$RUN_POLICY_SIGNATURE" "$RUN_POLICY_TAMPER" "$RUN_NETWORK_PARTITION" "$RUN_REDPANDA_BOUNCE" "$RUN_DETERMINISM" "$STRICT_CONTROLS" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
verification_summary = pathlib.Path(sys.argv[2]).resolve()
verification_ok = sys.argv[3].lower() == "true"
verification_exit_code = int(sys.argv[4])
git_commit = sys.argv[5]
git_branch = sys.argv[6]
run_checks = sys.argv[7].lower() == "true"
run_extended_checks = sys.argv[8].lower() == "true"
run_load_profiles = sys.argv[9].lower() == "true"
run_startup_guardrails = sys.argv[10].lower() == "true"
run_change_workflow = sys.argv[11].lower() == "true"
run_adversarial = sys.argv[12].lower() == "true"
run_policy_signature = sys.argv[13].lower() == "true"
run_policy_tamper = sys.argv[14].lower() == "true"
run_network_partition = sys.argv[15].lower() == "true"
run_redpanda_bounce = sys.argv[16].lower() == "true"
run_determinism = sys.argv[17].lower() == "true"
strict_controls = sys.argv[18].lower() == "true"

with open(verification_summary, "r", encoding="utf-8") as f:
    summary = json.load(f)

controls_report_path = summary.get("artifacts", {}).get("controls_check_report")
budget_report_path = summary.get("artifacts", {}).get("safety_budget_report")
controls_advisory_missing = None
controls_advisory_stale = None
controls_failed_enforced_stale = None
safety_budget_ok = None
safety_budget_violations = []
adversarial_tests_ok = None
adversarial_failed_steps = []
policy_smoke_ok = None
policy_tamper_ok = None
policy_tamper_detected = None
compliance_require_full_mapping = summary.get("compliance_require_full_mapping")
compliance_ok = None
compliance_missing_controls_count = None
compliance_unmapped_controls_count = None
compliance_unmapped_enforced_controls_count = None
compliance_mapping_coverage_ratio = None
network_partition_ok = None
network_partition_during_reachable = None
network_partition_recovered = None
redpanda_bounce_ok = None
redpanda_bounce_during_reachable = None
redpanda_bounce_recovered = None
determinism_ok = None
determinism_executed_runs = None
determinism_distinct_hash_count = None
if controls_report_path:
    candidate = pathlib.Path(controls_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            controls_payload = json.load(f)
        controls_advisory_missing = int(controls_payload.get("advisory_missing_count", 0))
        controls_advisory_stale = int(controls_payload.get("advisory_stale_count", 0))
        controls_failed_enforced_stale = int(
            controls_payload.get("failed_enforced_stale_count", 0)
        )
if budget_report_path:
    candidate = pathlib.Path(budget_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            budget_payload = json.load(f)
        safety_budget_ok = bool(budget_payload.get("ok", False))
        safety_budget_violations = list(budget_payload.get("violations", []) or [])
adversarial_report_path = summary.get("artifacts", {}).get("adversarial_tests_report")
if adversarial_report_path:
    candidate = pathlib.Path(adversarial_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            adversarial_payload = json.load(f)
        adversarial_tests_ok = bool(adversarial_payload.get("ok", False))
        adversarial_failed_steps = [
            str(step.get("name"))
            for step in (adversarial_payload.get("steps", []) or [])
            if step.get("status") == "fail"
        ]
policy_smoke_report_path = summary.get("artifacts", {}).get("policy_smoke_report")
if policy_smoke_report_path:
    candidate = pathlib.Path(policy_smoke_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            policy_payload = json.load(f)
        policy_smoke_ok = bool(policy_payload.get("ok", False))
policy_tamper_report_path = summary.get("artifacts", {}).get("prove_policy_tamper_report")
if policy_tamper_report_path:
    candidate = pathlib.Path(policy_tamper_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            tamper_payload = json.load(f)
        policy_tamper_ok = bool(tamper_payload.get("ok", False))
        policy_tamper_detected = bool(tamper_payload.get("tamper_detected", False))
compliance_report_path = summary.get("artifacts", {}).get("compliance_evidence_report")
if compliance_report_path:
    candidate = pathlib.Path(compliance_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            compliance_payload = json.load(f)
        compliance_ok = bool(compliance_payload.get("ok", False))
        compliance_require_full_mapping = compliance_payload.get(
            "require_full_mapping", compliance_require_full_mapping
        )
        compliance_missing_controls_count = compliance_payload.get("missing_controls_count")
        compliance_unmapped_controls_count = compliance_payload.get("unmapped_controls_count")
        compliance_unmapped_enforced_controls_count = compliance_payload.get("unmapped_enforced_controls_count")
        compliance_mapping_coverage_ratio = compliance_payload.get("mapping_coverage_ratio")
network_partition_report_path = summary.get("artifacts", {}).get("network_partition_runbook_dir")
if network_partition_report_path:
    candidate_dir = pathlib.Path(network_partition_report_path)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "chaos/network-partition-latest.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            network_payload = json.load(f)
        connectivity = network_payload.get("connectivity", {}) if isinstance(network_payload, dict) else {}
        network_partition_ok = bool(network_payload.get("ok", False))
        network_partition_during_reachable = connectivity.get("during_partition_broker_reachable")
        network_partition_recovered = connectivity.get("after_recovery_broker_reachable")
redpanda_bounce_report_path = summary.get("artifacts", {}).get("redpanda_bounce_runbook_dir")
if redpanda_bounce_report_path:
    candidate_dir = pathlib.Path(redpanda_bounce_report_path)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "chaos/redpanda-broker-bounce-latest.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            redpanda_payload = json.load(f)
        connectivity = redpanda_payload.get("connectivity", {}) if isinstance(redpanda_payload, dict) else {}
        redpanda_bounce_ok = bool(redpanda_payload.get("ok", False))
        redpanda_bounce_during_reachable = connectivity.get("during_stop_broker_reachable")
        redpanda_bounce_recovered = connectivity.get("after_restart_broker_reachable")
determinism_report_path = summary.get("artifacts", {}).get("prove_determinism_report")
if determinism_report_path:
    candidate = pathlib.Path(determinism_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            determinism_payload = json.load(f)
        determinism_ok = bool(determinism_payload.get("ok", False))
        determinism_executed_runs = determinism_payload.get("executed_runs")
        determinism_distinct_hash_count = len(determinism_payload.get("distinct_hashes", []) or [])

controls_gate_ok = True
if strict_controls:
    controls_gate_ok = controls_advisory_missing == 0

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": verification_ok and bool(summary.get("ok", False)) and controls_gate_ok,
    "git_commit": git_commit,
    "git_branch": git_branch,
    "verification_exit_code": verification_exit_code,
    "run_checks": run_checks,
    "run_extended_checks": run_extended_checks,
    "run_load_profiles": run_load_profiles,
    "run_startup_guardrails": run_startup_guardrails,
    "run_change_workflow": run_change_workflow,
    "run_adversarial": run_adversarial,
    "run_policy_signature": run_policy_signature,
    "run_policy_tamper": run_policy_tamper,
    "run_network_partition": run_network_partition,
    "run_redpanda_bounce": run_redpanda_bounce,
    "run_determinism": run_determinism,
    "strict_controls": strict_controls,
    "controls_advisory_missing_count": controls_advisory_missing,
    "controls_advisory_stale_count": controls_advisory_stale,
    "controls_failed_enforced_stale_count": controls_failed_enforced_stale,
    "safety_budget_ok": safety_budget_ok,
    "safety_budget_violations": safety_budget_violations,
    "adversarial_tests_ok": adversarial_tests_ok,
    "adversarial_failed_steps": adversarial_failed_steps,
    "policy_smoke_ok": policy_smoke_ok,
    "policy_tamper_ok": policy_tamper_ok,
    "policy_tamper_detected": policy_tamper_detected,
    "compliance_require_full_mapping": compliance_require_full_mapping,
    "compliance_ok": compliance_ok,
    "compliance_missing_controls_count": compliance_missing_controls_count,
    "compliance_unmapped_controls_count": compliance_unmapped_controls_count,
    "compliance_unmapped_enforced_controls_count": compliance_unmapped_enforced_controls_count,
    "compliance_mapping_coverage_ratio": compliance_mapping_coverage_ratio,
    "network_partition_ok": network_partition_ok,
    "network_partition_during_reachable": network_partition_during_reachable,
    "network_partition_recovered": network_partition_recovered,
    "redpanda_bounce_ok": redpanda_bounce_ok,
    "redpanda_bounce_during_reachable": redpanda_bounce_during_reachable,
    "redpanda_bounce_recovered": redpanda_bounce_recovered,
    "determinism_ok": determinism_ok,
    "determinism_executed_runs": determinism_executed_runs,
    "determinism_distinct_hash_count": determinism_distinct_hash_count,
    "controls_gate_ok": controls_gate_ok,
    "verification_run_load_profiles": bool(summary.get("run_load_profiles", False)),
    "verification_run_startup_guardrails": bool(summary.get("run_startup_guardrails", False)),
    "verification_run_change_workflow": bool(summary.get("run_change_workflow", False)),
    "verification_run_adversarial": bool(summary.get("run_adversarial", False)),
    "verification_run_policy_signature": bool(summary.get("run_policy_signature", False)),
    "verification_run_policy_tamper": bool(summary.get("run_policy_tamper", False)),
    "verification_run_network_partition": bool(summary.get("run_network_partition", False)),
    "verification_run_redpanda_bounce": bool(summary.get("run_redpanda_bounce", False)),
    "verification_run_determinism": bool(summary.get("run_determinism", False)),
    "verification_summary": str(verification_summary),
    "verification_step_count": len(summary.get("steps", [])),
    "failed_steps": [s.get("name") for s in summary.get("steps", []) if s.get("status") != "pass"],
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

GATE_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "release_gate_report=${REPORT_FILE}"
echo "release_gate_latest=${LATEST_FILE}"
echo "release_gate_ok=${GATE_OK}"

if [[ "$GATE_OK" != "true" ]]; then
  exit 1
fi
