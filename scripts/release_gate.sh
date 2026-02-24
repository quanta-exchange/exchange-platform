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
RUN_EXACTLY_ONCE_RUNBOOK=false
RUN_MAPPING_INTEGRITY_RUNBOOK=false
RUN_MAPPING_COVERAGE_RUNBOOK=false
RUN_IDEMPOTENCY_LATCH_RUNBOOK=false
RUN_PROOF_HEALTH_RUNBOOK=false
RUN_DETERMINISM=false
RUN_EXACTLY_ONCE_MILLION=false
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
    --run-exactly-once-runbook)
      RUN_EXACTLY_ONCE_RUNBOOK=true
      shift
      ;;
    --run-mapping-integrity-runbook)
      RUN_MAPPING_INTEGRITY_RUNBOOK=true
      shift
      ;;
    --run-mapping-coverage-runbook)
      RUN_MAPPING_COVERAGE_RUNBOOK=true
      shift
      ;;
    --run-idempotency-latch-runbook)
      RUN_IDEMPOTENCY_LATCH_RUNBOOK=true
      shift
      ;;
    --run-proof-health-runbook)
      RUN_PROOF_HEALTH_RUNBOOK=true
      shift
      ;;
    --run-determinism)
      RUN_DETERMINISM=true
      shift
      ;;
    --run-exactly-once-million)
      RUN_EXACTLY_ONCE_MILLION=true
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
if [[ "$RUN_EXACTLY_ONCE_RUNBOOK" == "true" ]]; then
  VERIFY_CMD+=("--run-exactly-once-runbook")
fi
if [[ "$RUN_MAPPING_INTEGRITY_RUNBOOK" == "true" ]]; then
  VERIFY_CMD+=("--run-mapping-integrity-runbook")
fi
if [[ "$RUN_MAPPING_COVERAGE_RUNBOOK" == "true" ]]; then
  VERIFY_CMD+=("--run-mapping-coverage-runbook")
fi
if [[ "$RUN_IDEMPOTENCY_LATCH_RUNBOOK" == "true" ]]; then
  VERIFY_CMD+=("--run-idempotency-latch-runbook")
fi
if [[ "$RUN_PROOF_HEALTH_RUNBOOK" == "true" ]]; then
  VERIFY_CMD+=("--run-proof-health-runbook")
fi
if [[ "$RUN_DETERMINISM" == "true" ]]; then
  VERIFY_CMD+=("--run-determinism")
fi
if [[ "$RUN_EXACTLY_ONCE_MILLION" == "true" ]]; then
  VERIFY_CMD+=("--run-exactly-once-million")
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

python3 - "$REPORT_FILE" "$VERIFY_SUMMARY" "$VERIFY_OK" "$VERIFY_EXIT_CODE" "$COMMIT" "$BRANCH" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$RUN_LOAD_PROFILES" "$RUN_STARTUP_GUARDRAILS" "$RUN_CHANGE_WORKFLOW" "$RUN_ADVERSARIAL" "$RUN_POLICY_SIGNATURE" "$RUN_POLICY_TAMPER" "$RUN_NETWORK_PARTITION" "$RUN_REDPANDA_BOUNCE" "$RUN_EXACTLY_ONCE_RUNBOOK" "$RUN_DETERMINISM" "$RUN_EXACTLY_ONCE_MILLION" "$STRICT_CONTROLS" "$RUN_MAPPING_INTEGRITY_RUNBOOK" "$RUN_IDEMPOTENCY_LATCH_RUNBOOK" "$RUN_PROOF_HEALTH_RUNBOOK" "$RUN_MAPPING_COVERAGE_RUNBOOK" <<'PY'
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
run_exactly_once_runbook = sys.argv[17].lower() == "true"
run_determinism = sys.argv[18].lower() == "true"
run_exactly_once_million = sys.argv[19].lower() == "true"
strict_controls = sys.argv[20].lower() == "true"
run_mapping_integrity_runbook = sys.argv[21].lower() == "true"
run_idempotency_latch_runbook = sys.argv[22].lower() == "true"
run_proof_health_runbook = sys.argv[23].lower() == "true"
run_mapping_coverage_runbook = sys.argv[24].lower() == "true"

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
compliance_duplicate_mapping_ids_count = None
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
idempotency_scope_ok = None
idempotency_scope_passed = None
idempotency_scope_failed = None
idempotency_key_format_ok = None
idempotency_key_format_missing_tests_count = None
idempotency_key_format_failed_tests_count = None
latch_approval_ok = None
latch_approval_missing_tests_count = None
latch_approval_failed_tests_count = None
exactly_once_million_ok = None
exactly_once_million_repeats = None
exactly_once_million_concurrency = None
exactly_once_runbook_proof_ok = None
exactly_once_runbook_proof_repeats = None
exactly_once_runbook_recommended_action = None
mapping_integrity_ok = None
mapping_coverage_ok = None
mapping_coverage_ratio = None
mapping_coverage_missing_controls_count = None
mapping_coverage_unmapped_controls_count = None
mapping_coverage_duplicate_mapping_ids_count = None
mapping_coverage_duplicate_control_ids_count = None
mapping_coverage_metrics_ok = None
mapping_coverage_metrics_health_ok = None
mapping_coverage_metrics_ratio = None
mapping_coverage_metrics_missing_controls_count = None
mapping_coverage_metrics_unmapped_enforced_controls_count = None
mapping_coverage_metrics_duplicate_control_ids_count = None
mapping_coverage_metrics_duplicate_mapping_ids_count = None
mapping_coverage_metrics_runbook_recommended_action = None
mapping_integrity_runbook_proof_ok = None
mapping_integrity_runbook_recommended_action = None
mapping_coverage_runbook_proof_ok = None
mapping_coverage_runbook_recommended_action = None
proof_health_ok = None
proof_health_health_ok = None
proof_health_missing_count = None
proof_health_failing_count = None
idempotency_latch_runbook_idempotency_ok = None
idempotency_latch_runbook_latch_ok = None
idempotency_latch_runbook_recommended_action = None
proof_health_runbook_proof_ok = None
proof_health_runbook_missing_count = None
proof_health_runbook_failing_count = None
proof_health_runbook_recommended_action = None
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
        compliance_duplicate_mapping_ids_count = compliance_payload.get(
            "duplicate_mapping_ids_count"
        )
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
idempotency_scope_report_path = summary.get("artifacts", {}).get("prove_idempotency_report")
if idempotency_scope_report_path:
    candidate = pathlib.Path(idempotency_scope_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            idempotency_payload = json.load(f)
        idempotency_scope_ok = bool(idempotency_payload.get("ok", False))
        idempotency_scope_passed = idempotency_payload.get("passed")
        idempotency_scope_failed = idempotency_payload.get("failed")
idempotency_key_format_report_path = summary.get("artifacts", {}).get(
    "prove_idempotency_key_format_report"
)
idempotency_key_format_candidate = None
if idempotency_key_format_report_path:
    idempotency_key_format_candidate = pathlib.Path(idempotency_key_format_report_path)
    if not idempotency_key_format_candidate.is_absolute():
        idempotency_key_format_candidate = (
            verification_summary.parent / idempotency_key_format_candidate
        ).resolve()
else:
    repo_root = verification_summary.parents[2]
    idempotency_key_format_candidate = (
        repo_root / "build/idempotency/prove-idempotency-key-format-latest.json"
    )

if idempotency_key_format_candidate and idempotency_key_format_candidate.exists():
    with open(idempotency_key_format_candidate, "r", encoding="utf-8") as f:
        idempotency_key_format_payload = json.load(f)
    idempotency_key_format_ok = bool(idempotency_key_format_payload.get("ok", False))
    idempotency_key_format_missing_tests_count = len(
        idempotency_key_format_payload.get("missing_tests", []) or []
    )
    idempotency_key_format_failed_tests_count = len(
        idempotency_key_format_payload.get("failed_tests", []) or []
    )
latch_approval_report_path = summary.get("artifacts", {}).get("prove_latch_approval_report")
if latch_approval_report_path:
    candidate = pathlib.Path(latch_approval_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            latch_payload = json.load(f)
        latch_approval_ok = bool(latch_payload.get("ok", False))
        latch_approval_missing_tests_count = len(latch_payload.get("missing_tests", []) or [])
        latch_approval_failed_tests_count = len(latch_payload.get("failed_tests", []) or [])
exactly_once_million_report_path = summary.get("artifacts", {}).get(
    "prove_exactly_once_million_report"
)
if exactly_once_million_report_path:
    candidate = pathlib.Path(exactly_once_million_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            exactly_once_payload = json.load(f)
        exactly_once_million_ok = bool(exactly_once_payload.get("ok", False))
        exactly_once_million_repeats = exactly_once_payload.get("repeats")
        exactly_once_million_concurrency = exactly_once_payload.get("concurrency")
exactly_once_runbook_dir = summary.get("artifacts", {}).get("exactly_once_runbook_dir")
if exactly_once_runbook_dir:
    candidate_dir = pathlib.Path(exactly_once_runbook_dir)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "exactly-once-million-summary.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            runbook_payload = json.load(f)
        exactly_once_runbook_proof_ok = bool(runbook_payload.get("proof_ok", False))
        exactly_once_runbook_proof_repeats = runbook_payload.get("proof_repeats")
        exactly_once_runbook_recommended_action = runbook_payload.get("recommended_action")
mapping_integrity_report_path = summary.get("artifacts", {}).get("prove_mapping_integrity_report")
if mapping_integrity_report_path:
    candidate = pathlib.Path(mapping_integrity_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            mapping_integrity_payload = json.load(f)
        mapping_integrity_ok = bool(mapping_integrity_payload.get("ok", False))
mapping_coverage_report_path = summary.get("artifacts", {}).get("prove_mapping_coverage_report")
if mapping_coverage_report_path:
    candidate = pathlib.Path(mapping_coverage_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            mapping_coverage_payload = json.load(f)
        mapping_coverage_ok = bool(mapping_coverage_payload.get("ok", False))
        mapping_coverage_ratio = mapping_coverage_payload.get("mapping_coverage_ratio")
        mapping_coverage_missing_controls_count = mapping_coverage_payload.get(
            "missing_controls_count"
        )
        mapping_coverage_unmapped_controls_count = mapping_coverage_payload.get(
            "unmapped_controls_count"
        )
        mapping_coverage_duplicate_mapping_ids_count = mapping_coverage_payload.get(
            "duplicate_mapping_ids_count"
        )
        mapping_coverage_duplicate_control_ids_count = mapping_coverage_payload.get(
            "duplicate_control_ids_count"
        )
mapping_coverage_metrics_report_path = summary.get("artifacts", {}).get(
    "mapping_coverage_metrics_report"
)
mapping_coverage_metrics_candidate = None
if mapping_coverage_metrics_report_path:
    mapping_coverage_metrics_candidate = pathlib.Path(mapping_coverage_metrics_report_path)
    if not mapping_coverage_metrics_candidate.is_absolute():
        mapping_coverage_metrics_candidate = (
            verification_summary.parent / mapping_coverage_metrics_candidate
        ).resolve()
else:
    # Fallback for legacy verification summaries that do not expose the metrics artifact.
    repo_root = verification_summary.parents[2]
    mapping_coverage_metrics_candidate = (
        repo_root / "build/metrics/mapping-coverage-latest.json"
    )

if mapping_coverage_metrics_candidate and mapping_coverage_metrics_candidate.exists():
    with open(mapping_coverage_metrics_candidate, "r", encoding="utf-8") as f:
        mapping_coverage_metrics_payload = json.load(f)
    mapping_coverage_metrics_ok = bool(mapping_coverage_metrics_payload.get("ok", False))
    mapping_coverage_metrics_health_ok = bool(
        mapping_coverage_metrics_payload.get(
            "health_ok", mapping_coverage_metrics_ok
        )
    )
    mapping_coverage_metrics_ratio = mapping_coverage_metrics_payload.get(
        "mapping_coverage_ratio"
    )
    mapping_coverage_metrics_missing_controls_count = (
        mapping_coverage_metrics_payload.get("missing_controls_count")
    )
    mapping_coverage_metrics_unmapped_enforced_controls_count = (
        mapping_coverage_metrics_payload.get("unmapped_enforced_controls_count")
    )
    mapping_coverage_metrics_duplicate_control_ids_count = (
        mapping_coverage_metrics_payload.get("duplicate_control_ids_count")
    )
    mapping_coverage_metrics_duplicate_mapping_ids_count = (
        mapping_coverage_metrics_payload.get("duplicate_mapping_ids_count")
    )
    mapping_coverage_metrics_runbook_recommended_action = (
        mapping_coverage_metrics_payload.get("runbook_recommended_action")
    )
proof_health_report_path = summary.get("artifacts", {}).get("proof_health_metrics_report")
if proof_health_report_path:
    candidate = pathlib.Path(proof_health_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            proof_health_payload = json.load(f)
        proof_health_ok = bool(proof_health_payload.get("ok", False))
        proof_health_health_ok = bool(proof_health_payload.get("health_ok", proof_health_ok))
        proof_health_missing_count = proof_health_payload.get("missing_count")
        proof_health_failing_count = proof_health_payload.get("failing_count")
mapping_integrity_runbook_dir = summary.get("artifacts", {}).get(
    "mapping_integrity_runbook_dir"
)
if mapping_integrity_runbook_dir:
    candidate_dir = pathlib.Path(mapping_integrity_runbook_dir)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "mapping-integrity-summary.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            mapping_runbook_payload = json.load(f)
        mapping_integrity_runbook_proof_ok = bool(
            mapping_runbook_payload.get("proof_ok", False)
        )
        mapping_integrity_runbook_recommended_action = mapping_runbook_payload.get(
            "recommended_action"
        )
mapping_coverage_runbook_dir = summary.get("artifacts", {}).get(
    "mapping_coverage_runbook_dir"
)
if mapping_coverage_runbook_dir:
    candidate_dir = pathlib.Path(mapping_coverage_runbook_dir)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "mapping-coverage-summary.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            mapping_coverage_runbook_payload = json.load(f)
        mapping_coverage_runbook_proof_ok = bool(
            mapping_coverage_runbook_payload.get("proof_ok", False)
        )
        mapping_coverage_runbook_recommended_action = (
            mapping_coverage_runbook_payload.get("recommended_action")
        )
idempotency_latch_runbook_dir = summary.get("artifacts", {}).get(
    "idempotency_latch_runbook_dir"
)
if idempotency_latch_runbook_dir:
    candidate_dir = pathlib.Path(idempotency_latch_runbook_dir)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "idempotency-latch-summary.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            idempotency_latch_payload = json.load(f)
        idempotency_latch_runbook_idempotency_ok = bool(
            idempotency_latch_payload.get("idempotency_ok", False)
        )
        idempotency_latch_runbook_latch_ok = bool(
            idempotency_latch_payload.get("latch_ok", False)
        )
        idempotency_latch_runbook_recommended_action = idempotency_latch_payload.get(
            "recommended_action"
        )
proof_health_runbook_dir = summary.get("artifacts", {}).get("proof_health_runbook_dir")
if proof_health_runbook_dir:
    candidate_dir = pathlib.Path(proof_health_runbook_dir)
    if not candidate_dir.is_absolute():
        candidate_dir = (verification_summary.parent / candidate_dir).resolve()
    candidate = candidate_dir / "proof-health-summary.json"
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            proof_health_runbook_payload = json.load(f)
        proof_health_runbook_proof_ok = bool(
            proof_health_runbook_payload.get("proof_health_ok", False)
        )
        proof_health_runbook_missing_count = proof_health_runbook_payload.get("missing_count")
        proof_health_runbook_failing_count = proof_health_runbook_payload.get("failing_count")
        proof_health_runbook_recommended_action = proof_health_runbook_payload.get(
            "recommended_action"
        )

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
    "run_exactly_once_runbook": run_exactly_once_runbook,
    "run_mapping_integrity_runbook": run_mapping_integrity_runbook,
    "run_mapping_coverage_runbook": run_mapping_coverage_runbook,
    "run_idempotency_latch_runbook": run_idempotency_latch_runbook,
    "run_proof_health_runbook": run_proof_health_runbook,
    "run_determinism": run_determinism,
    "run_exactly_once_million": run_exactly_once_million,
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
    "compliance_duplicate_mapping_ids_count": compliance_duplicate_mapping_ids_count,
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
    "idempotency_scope_ok": idempotency_scope_ok,
    "idempotency_scope_passed": idempotency_scope_passed,
    "idempotency_scope_failed": idempotency_scope_failed,
    "idempotency_key_format_ok": idempotency_key_format_ok,
    "idempotency_key_format_missing_tests_count": idempotency_key_format_missing_tests_count,
    "idempotency_key_format_failed_tests_count": idempotency_key_format_failed_tests_count,
    "latch_approval_ok": latch_approval_ok,
    "latch_approval_missing_tests_count": latch_approval_missing_tests_count,
    "latch_approval_failed_tests_count": latch_approval_failed_tests_count,
    "exactly_once_million_ok": exactly_once_million_ok,
    "exactly_once_million_repeats": exactly_once_million_repeats,
    "exactly_once_million_concurrency": exactly_once_million_concurrency,
    "exactly_once_runbook_proof_ok": exactly_once_runbook_proof_ok,
    "exactly_once_runbook_proof_repeats": exactly_once_runbook_proof_repeats,
    "exactly_once_runbook_recommended_action": exactly_once_runbook_recommended_action,
    "mapping_integrity_ok": mapping_integrity_ok,
    "mapping_coverage_ok": mapping_coverage_ok,
    "mapping_coverage_ratio": mapping_coverage_ratio,
    "mapping_coverage_missing_controls_count": mapping_coverage_missing_controls_count,
    "mapping_coverage_unmapped_controls_count": mapping_coverage_unmapped_controls_count,
    "mapping_coverage_duplicate_mapping_ids_count": mapping_coverage_duplicate_mapping_ids_count,
    "mapping_coverage_duplicate_control_ids_count": mapping_coverage_duplicate_control_ids_count,
    "mapping_coverage_metrics_ok": mapping_coverage_metrics_ok,
    "mapping_coverage_metrics_health_ok": mapping_coverage_metrics_health_ok,
    "mapping_coverage_metrics_ratio": mapping_coverage_metrics_ratio,
    "mapping_coverage_metrics_missing_controls_count": mapping_coverage_metrics_missing_controls_count,
    "mapping_coverage_metrics_unmapped_enforced_controls_count": mapping_coverage_metrics_unmapped_enforced_controls_count,
    "mapping_coverage_metrics_duplicate_control_ids_count": mapping_coverage_metrics_duplicate_control_ids_count,
    "mapping_coverage_metrics_duplicate_mapping_ids_count": mapping_coverage_metrics_duplicate_mapping_ids_count,
    "mapping_coverage_metrics_runbook_recommended_action": mapping_coverage_metrics_runbook_recommended_action,
    "mapping_integrity_runbook_proof_ok": mapping_integrity_runbook_proof_ok,
    "mapping_integrity_runbook_recommended_action": mapping_integrity_runbook_recommended_action,
    "mapping_coverage_runbook_proof_ok": mapping_coverage_runbook_proof_ok,
    "mapping_coverage_runbook_recommended_action": mapping_coverage_runbook_recommended_action,
    "proof_health_ok": proof_health_ok,
    "proof_health_health_ok": proof_health_health_ok,
    "proof_health_missing_count": proof_health_missing_count,
    "proof_health_failing_count": proof_health_failing_count,
    "idempotency_latch_runbook_idempotency_ok": idempotency_latch_runbook_idempotency_ok,
    "idempotency_latch_runbook_latch_ok": idempotency_latch_runbook_latch_ok,
    "idempotency_latch_runbook_recommended_action": idempotency_latch_runbook_recommended_action,
    "proof_health_runbook_proof_ok": proof_health_runbook_proof_ok,
    "proof_health_runbook_missing_count": proof_health_runbook_missing_count,
    "proof_health_runbook_failing_count": proof_health_runbook_failing_count,
    "proof_health_runbook_recommended_action": proof_health_runbook_recommended_action,
    "controls_gate_ok": controls_gate_ok,
    "verification_run_load_profiles": bool(summary.get("run_load_profiles", False)),
    "verification_run_startup_guardrails": bool(summary.get("run_startup_guardrails", False)),
    "verification_run_change_workflow": bool(summary.get("run_change_workflow", False)),
    "verification_run_adversarial": bool(summary.get("run_adversarial", False)),
    "verification_run_policy_signature": bool(summary.get("run_policy_signature", False)),
    "verification_run_policy_tamper": bool(summary.get("run_policy_tamper", False)),
    "verification_run_network_partition": bool(summary.get("run_network_partition", False)),
    "verification_run_redpanda_bounce": bool(summary.get("run_redpanda_bounce", False)),
    "verification_run_exactly_once_runbook": bool(
        summary.get("run_exactly_once_runbook", False)
    ),
    "verification_run_mapping_integrity_runbook": bool(
        summary.get("run_mapping_integrity_runbook", False)
    ),
    "verification_run_mapping_coverage_runbook": bool(
        summary.get("run_mapping_coverage_runbook", False)
    ),
    "verification_run_idempotency_latch_runbook": bool(
        summary.get("run_idempotency_latch_runbook", False)
    ),
    "verification_run_proof_health_runbook": bool(
        summary.get("run_proof_health_runbook", False)
    ),
    "verification_run_determinism": bool(summary.get("run_determinism", False)),
    "verification_run_exactly_once_million": bool(
        summary.get("run_exactly_once_million", False)
    ),
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
