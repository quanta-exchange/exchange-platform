#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/transparency}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/transparency-report-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/transparency-report-latest.json"

python3 - "$ROOT_DIR" "$REPORT_FILE" <<'PY'
import json
import pathlib
import re
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1]).resolve()
report_file = pathlib.Path(sys.argv[2]).resolve()

def read_json(rel_path):
    path = root / rel_path
    if not path.exists():
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

load = read_json("build/load/load-smoke.json")
dr = read_json("build/dr/dr-report.json")
invariants = read_json("build/invariants/ledger-invariants.json")
core_invariants = read_json("build/invariants/core-invariants.json")
invariants_summary = read_json("build/invariants/invariants-summary.json")
determinism = read_json("build/determinism/prove-determinism-latest.json")
idempotency_scope = read_json("build/idempotency/prove-idempotency-latest.json")
idempotency_key_format = read_json("build/idempotency/prove-idempotency-key-format-latest.json")
latch_approval = read_json("build/latch/prove-latch-approval-latest.json")
exactly_once_million = read_json("build/exactly-once/prove-exactly-once-million-latest.json")
ws = read_json("build/ws/ws-smoke.json")
ws_resume = read_json("build/ws/ws-resume-smoke.json")
safety_budget = read_json("build/safety/safety-budget-latest.json")
snapshot_verify = read_json("build/snapshot/snapshot-verify-latest.json")
controls = read_json("build/controls/controls-check-latest.json")
controls_freshness = read_json("build/controls/prove-controls-freshness-latest.json")
compliance = read_json("build/compliance/compliance-evidence-latest.json")
mapping_integrity = read_json("build/compliance/prove-mapping-integrity-latest.json")
mapping_coverage = read_json("build/compliance/prove-mapping-coverage-latest.json")
mapping_coverage_metrics = read_json("build/metrics/mapping-coverage-latest.json")
audit_chain = read_json("build/audit/verify-audit-chain-latest.json")
change_audit_chain = read_json("build/change-audit/verify-change-audit-chain-latest.json")
pii_log_scan = read_json("build/security/pii-log-scan-latest.json")
rbac_sod = read_json("build/security/rbac-sod-check-latest.json")
anomaly = read_json("build/anomaly/anomaly-detector-latest.json")
budget_freshness = read_json("build/safety/prove-budget-freshness-latest.json")
proof_health = read_json("build/metrics/proof-health-latest.json")
release_gate = read_json("build/release-gate/release-gate-latest.json")
release_gate_fallback_smoke = read_json(
    "build/release-gate-smoke/release-gate-fallback-smoke-latest.json"
)
release_gate_context_proof = read_json(
    "build/release-gate/prove-release-gate-context-latest.json"
)
policy_smoke = read_json("build/policy-smoke/policy-smoke-latest.json")
policy_tamper = read_json("build/policy/prove-policy-tamper-latest.json")
network_partition = read_json("build/chaos/network-partition-latest.json")
redpanda_bounce = read_json("build/chaos/redpanda-broker-bounce-latest.json")
adversarial = read_json("build/adversarial/adversarial-tests-latest.json")
policy_signature_runbook = read_json("build/runbooks/policy-signature-latest.json")
policy_tamper_runbook = read_json("build/runbooks/policy-tamper-latest.json")
network_partition_runbook = read_json("build/runbooks/network-partition-latest.json")
redpanda_bounce_runbook = read_json("build/runbooks/redpanda-broker-bounce-latest.json")
adversarial_runbook = read_json("build/runbooks/adversarial-reliability-latest.json")
exactly_once_runbook = read_json("build/runbooks/exactly-once-million-latest.json")
mapping_integrity_runbook = read_json("build/runbooks/mapping-integrity-latest.json")
mapping_coverage_runbook = read_json("build/runbooks/mapping-coverage-latest.json")
idempotency_latch_runbook = read_json("build/runbooks/idempotency-latch-latest.json")
idempotency_key_format_runbook = read_json("build/runbooks/idempotency-key-format-latest.json")
proof_health_runbook = read_json("build/runbooks/proof-health-latest.json")
release_gate_context_runbook = read_json("build/runbooks/release-gate-context-latest.json")

sources = {
    "load": load,
    "dr": dr,
    "invariants": invariants,
    "core_invariants": core_invariants,
    "invariants_summary": invariants_summary,
    "determinism": determinism,
    "idempotency_scope": idempotency_scope,
    "idempotency_key_format": idempotency_key_format,
    "latch_approval": latch_approval,
    "exactly_once_million": exactly_once_million,
    "ws": ws,
    "ws_resume": ws_resume,
    "safety_budget": safety_budget,
    "snapshot_verify": snapshot_verify,
    "controls": controls,
    "controls_freshness": controls_freshness,
    "compliance": compliance,
    "mapping_integrity": mapping_integrity,
    "mapping_coverage": mapping_coverage,
    "mapping_coverage_metrics": mapping_coverage_metrics,
    "audit_chain": audit_chain,
    "change_audit_chain": change_audit_chain,
    "pii_log_scan": pii_log_scan,
    "rbac_sod": rbac_sod,
    "anomaly": anomaly,
    "budget_freshness": budget_freshness,
    "proof_health": proof_health,
    "release_gate": release_gate,
    "release_gate_fallback_smoke": release_gate_fallback_smoke,
    "release_gate_context_proof": release_gate_context_proof,
    "policy_smoke": policy_smoke,
    "policy_tamper": policy_tamper,
    "network_partition": network_partition,
    "redpanda_bounce": redpanda_bounce,
    "adversarial": adversarial,
    "policy_signature_runbook": policy_signature_runbook,
    "policy_tamper_runbook": policy_tamper_runbook,
    "network_partition_runbook": network_partition_runbook,
    "redpanda_bounce_runbook": redpanda_bounce_runbook,
    "adversarial_runbook": adversarial_runbook,
    "exactly_once_runbook": exactly_once_runbook,
    "mapping_integrity_runbook": mapping_integrity_runbook,
    "mapping_coverage_runbook": mapping_coverage_runbook,
    "idempotency_latch_runbook": idempotency_latch_runbook,
    "idempotency_key_format_runbook": idempotency_key_format_runbook,
    "proof_health_runbook": proof_health_runbook,
    "release_gate_context_runbook": release_gate_context_runbook,
}

email_pattern = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
suspicious_key_names = {
    "password",
    "secret",
    "privatekey",
    "private_key",
    "sessiontoken",
    "session_token",
    "apikey",
    "api_key",
    "accesskey",
    "access_key",
}

pii_hits = []
for name, payload in sources.items():
    if payload is None:
        continue

    def scan(value, path):
        if isinstance(value, dict):
            for k, v in value.items():
                normalized = re.sub(r"[^a-z0-9_]", "", str(k).lower())
                if normalized in suspicious_key_names:
                    if isinstance(v, str) and v.strip():
                        pii_hits.append(f"{name}:key:{'.'.join(path + [str(k)])}")
                scan(v, path + [str(k)])
            return
        if isinstance(value, list):
            for idx, item in enumerate(value):
                scan(item, path + [str(idx)])
            return
        if isinstance(value, str) and email_pattern.search(value):
            pii_hits.append(f"{name}:email:{'.'.join(path)}")

    scan(payload, [])

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(pii_hits) == 0,
    "summary": {
        "availability_proxy": {
            "load_thresholds_passed": bool(load.get("thresholds_passed")) if load else None,
            "order_p99_ms": float(load.get("order_p99_ms")) if load and load.get("order_p99_ms") is not None else None,
        },
        "integrity_proxy": {
            "invariants_ok": bool(invariants.get("ok")) if invariants else None,
            "core_invariants_ok": bool(core_invariants.get("ok")) if core_invariants else None,
            "core_order_transition_violations": int(core_invariants.get("order_transition_violations")) if core_invariants and core_invariants.get("order_transition_violations") is not None else None,
            "clickhouse_invariants_ok": bool(invariants_summary.get("clickhouse", {}).get("ok")) if invariants_summary else None,
            "dr_invariant_violations": int(dr.get("invariant_violations")) if dr and dr.get("invariant_violations") is not None else None,
            "safety_budget_ok": bool(safety_budget.get("ok")) if safety_budget else None,
            "snapshot_verify_ok": bool(snapshot_verify.get("ok")) if snapshot_verify else None,
            "determinism_ok": bool(determinism.get("ok")) if determinism else None,
            "determinism_executed_runs": int(determinism.get("executed_runs")) if determinism and determinism.get("executed_runs") is not None else None,
            "idempotency_scope_ok": bool(idempotency_scope.get("ok")) if idempotency_scope else None,
            "idempotency_scope_passed": int(idempotency_scope.get("passed")) if idempotency_scope and idempotency_scope.get("passed") is not None else None,
            "idempotency_key_format_ok": bool(idempotency_key_format.get("ok")) if idempotency_key_format else None,
            "idempotency_key_format_missing_tests_count": len((idempotency_key_format.get("missing_tests", []) or [])) if idempotency_key_format else None,
            "idempotency_key_format_failed_tests_count": len((idempotency_key_format.get("failed_tests", []) or [])) if idempotency_key_format else None,
            "latch_approval_ok": bool(latch_approval.get("ok")) if latch_approval else None,
            "latch_approval_missing_tests_count": len((latch_approval.get("missing_tests", []) or [])) if latch_approval else None,
            "exactly_once_million_ok": bool(exactly_once_million.get("ok")) if exactly_once_million else None,
            "exactly_once_million_repeats": int(exactly_once_million.get("repeats")) if exactly_once_million and exactly_once_million.get("repeats") is not None else None,
            "exactly_once_million_concurrency": int(exactly_once_million.get("concurrency")) if exactly_once_million and exactly_once_million.get("concurrency") is not None else None,
            "release_gate_context_proof_ok": bool(release_gate_context_proof.get("ok")) if release_gate_context_proof else None,
            "release_gate_context_proof_failed_checks_count": len((release_gate_context_proof.get("failed_checks", []) or [])) if release_gate_context_proof else None,
            "release_gate_context_proof_release_gate_present": bool((release_gate_context_proof.get("release_gate", {}) or {}).get("present")) if release_gate_context_proof else None,
            "release_gate_context_proof_fallback_present": bool((release_gate_context_proof.get("fallback_smoke", {}) or {}).get("present")) if release_gate_context_proof else None,
            "release_gate_context_proof_runbook_context_missing_count": int((release_gate_context_proof.get("release_gate", {}) or {}).get("runbook_context_missing_count")) if release_gate_context_proof and (release_gate_context_proof.get("release_gate", {}) or {}).get("runbook_context_missing_count") is not None else None,
            "release_gate_context_proof_fallback_missing_fields_count": int((release_gate_context_proof.get("fallback_smoke", {}) or {}).get("missing_fields_count")) if release_gate_context_proof and (release_gate_context_proof.get("fallback_smoke", {}) or {}).get("missing_fields_count") is not None else None,
        },
        "ws_proxy": {
            "ws_dropped_msgs": float(ws.get("metrics", {}).get("ws_dropped_msgs")) if ws else None,
            "ws_slow_closes": float(ws.get("metrics", {}).get("ws_slow_closes")) if ws else None,
            "ws_resume_gaps": float(ws_resume.get("metrics", {}).get("ws_resume_gaps")) if ws_resume else None,
            "ws_resume_gap_result_type": ws_resume.get("gap_recovery", {}).get("result_type") if ws_resume else None,
        },
        "governance_proxy": {
            "controls_ok": bool(controls.get("ok")) if controls else None,
            "controls_failed_enforced_stale_count": int(controls.get("failed_enforced_stale_count")) if controls and controls.get("failed_enforced_stale_count") is not None else None,
            "controls_advisory_stale_count": int(controls.get("advisory_stale_count")) if controls and controls.get("advisory_stale_count") is not None else None,
            "compliance_ok": bool(compliance.get("ok")) if compliance else None,
            "compliance_missing_controls_count": int(compliance.get("missing_controls_count")) if compliance and compliance.get("missing_controls_count") is not None else None,
            "compliance_duplicate_mapping_ids_count": int(compliance.get("duplicate_mapping_ids_count")) if compliance and compliance.get("duplicate_mapping_ids_count") is not None else None,
            "compliance_unmapped_controls_count": int(compliance.get("unmapped_controls_count")) if compliance and compliance.get("unmapped_controls_count") is not None else None,
            "compliance_unmapped_enforced_controls_count": int(compliance.get("unmapped_enforced_controls_count")) if compliance and compliance.get("unmapped_enforced_controls_count") is not None else None,
            "compliance_mapping_coverage_ratio": float(compliance.get("mapping_coverage_ratio")) if compliance and compliance.get("mapping_coverage_ratio") is not None else None,
            "mapping_integrity_ok": bool(mapping_integrity.get("ok")) if mapping_integrity else None,
            "mapping_coverage_ok": bool(mapping_coverage.get("ok")) if mapping_coverage else None,
            "mapping_coverage_ratio": float(mapping_coverage.get("mapping_coverage_ratio")) if mapping_coverage and mapping_coverage.get("mapping_coverage_ratio") is not None else None,
            "mapping_coverage_missing_controls_count": int(mapping_coverage.get("missing_controls_count")) if mapping_coverage and mapping_coverage.get("missing_controls_count") is not None else None,
            "mapping_coverage_unmapped_controls_count": int(mapping_coverage.get("unmapped_controls_count")) if mapping_coverage and mapping_coverage.get("unmapped_controls_count") is not None else None,
            "mapping_coverage_unmapped_enforced_controls_count": int(mapping_coverage.get("unmapped_enforced_controls_count")) if mapping_coverage and mapping_coverage.get("unmapped_enforced_controls_count") is not None else None,
            "mapping_coverage_duplicate_control_ids_count": int(mapping_coverage.get("duplicate_control_ids_count")) if mapping_coverage and mapping_coverage.get("duplicate_control_ids_count") is not None else None,
            "mapping_coverage_duplicate_mapping_ids_count": int(mapping_coverage.get("duplicate_mapping_ids_count")) if mapping_coverage and mapping_coverage.get("duplicate_mapping_ids_count") is not None else None,
            "mapping_coverage_metrics_ok": bool(mapping_coverage_metrics.get("ok")) if mapping_coverage_metrics else None,
            "mapping_coverage_metrics_health_ok": bool(mapping_coverage_metrics.get("health_ok")) if mapping_coverage_metrics else None,
            "mapping_coverage_metrics_export_ok": bool(mapping_coverage_metrics.get("export_ok")) if mapping_coverage_metrics else None,
            "mapping_coverage_metrics_ratio": float(mapping_coverage_metrics.get("mapping_coverage_ratio")) if mapping_coverage_metrics and mapping_coverage_metrics.get("mapping_coverage_ratio") is not None else None,
            "mapping_coverage_metrics_missing_controls_count": int(mapping_coverage_metrics.get("missing_controls_count")) if mapping_coverage_metrics and mapping_coverage_metrics.get("missing_controls_count") is not None else None,
            "mapping_coverage_metrics_unmapped_enforced_controls_count": int(mapping_coverage_metrics.get("unmapped_enforced_controls_count")) if mapping_coverage_metrics and mapping_coverage_metrics.get("unmapped_enforced_controls_count") is not None else None,
            "mapping_coverage_metrics_duplicate_control_ids_count": int(mapping_coverage_metrics.get("duplicate_control_ids_count")) if mapping_coverage_metrics and mapping_coverage_metrics.get("duplicate_control_ids_count") is not None else None,
            "mapping_coverage_metrics_duplicate_mapping_ids_count": int(mapping_coverage_metrics.get("duplicate_mapping_ids_count")) if mapping_coverage_metrics and mapping_coverage_metrics.get("duplicate_mapping_ids_count") is not None else None,
            "mapping_coverage_metrics_runbook_recommended_action": mapping_coverage_metrics.get("runbook_recommended_action") if mapping_coverage_metrics else None,
            "audit_chain_ok": bool(audit_chain.get("ok")) if audit_chain else None,
            "audit_chain_mode": audit_chain.get("mode") if audit_chain else None,
            "change_audit_chain_ok": bool(change_audit_chain.get("ok")) if change_audit_chain else None,
            "change_audit_chain_mode": change_audit_chain.get("mode") if change_audit_chain else None,
            "pii_log_scan_ok": bool(pii_log_scan.get("ok")) if pii_log_scan else None,
            "pii_log_scan_hit_count": int(pii_log_scan.get("hit_count")) if pii_log_scan and pii_log_scan.get("hit_count") is not None else None,
            "rbac_sod_ok": bool(rbac_sod.get("ok")) if rbac_sod else None,
            "anomaly_detector_ok": bool(anomaly.get("ok")) if anomaly else None,
            "anomaly_detected": bool(anomaly.get("anomaly_detected")) if anomaly else None,
            "policy_smoke_ok": bool(policy_smoke.get("ok")) if policy_smoke else None,
            "policy_signature_file": policy_smoke.get("signature_file") if policy_smoke else None,
            "policy_tamper_ok": bool(policy_tamper.get("ok")) if policy_tamper else None,
            "policy_tamper_detected": bool(policy_tamper.get("tamper_detected")) if policy_tamper else None,
            "policy_signature_runbook_ok": bool(policy_signature_runbook.get("runbook_ok")) if policy_signature_runbook and policy_signature_runbook.get("runbook_ok") is not None else None,
            "policy_signature_runbook_budget_ok": bool(policy_signature_runbook.get("budget_ok")) if policy_signature_runbook and policy_signature_runbook.get("budget_ok") is not None else None,
            "policy_signature_runbook_policy_ok": bool(policy_signature_runbook.get("policy_ok")) if policy_signature_runbook and policy_signature_runbook.get("policy_ok") is not None else None,
            "policy_signature_runbook_recommended_action": policy_signature_runbook.get("recommended_action") if policy_signature_runbook else None,
            "policy_tamper_runbook_ok": bool(policy_tamper_runbook.get("runbook_ok")) if policy_tamper_runbook and policy_tamper_runbook.get("runbook_ok") is not None else None,
            "policy_tamper_runbook_budget_ok": bool(policy_tamper_runbook.get("budget_ok")) if policy_tamper_runbook and policy_tamper_runbook.get("budget_ok") is not None else None,
            "policy_tamper_runbook_policy_tamper_ok": bool(policy_tamper_runbook.get("policy_tamper_ok")) if policy_tamper_runbook and policy_tamper_runbook.get("policy_tamper_ok") is not None else None,
            "policy_tamper_runbook_tamper_detected": bool(policy_tamper_runbook.get("tamper_detected")) if policy_tamper_runbook and policy_tamper_runbook.get("tamper_detected") is not None else None,
            "policy_tamper_runbook_recommended_action": policy_tamper_runbook.get("recommended_action") if policy_tamper_runbook else None,
            "chaos_network_partition_ok": bool(network_partition.get("ok")) if network_partition else None,
            "chaos_network_partition_method": (
                (network_partition.get("scenario", {}) or {}).get("applied_isolation_method")
                if network_partition
                else None
            ),
            "chaos_network_partition_during_reachable": (
                (network_partition.get("connectivity", {}) or {}).get("during_partition_broker_reachable")
                if network_partition
                else None
            ),
            "chaos_network_partition_after_recovery_reachable": (
                (network_partition.get("connectivity", {}) or {}).get("after_recovery_broker_reachable")
                if network_partition
                else None
            ),
            "chaos_redpanda_bounce_ok": bool(redpanda_bounce.get("ok")) if redpanda_bounce else None,
            "chaos_redpanda_bounce_during_reachable": (
                (redpanda_bounce.get("connectivity", {}) or {}).get("during_stop_broker_reachable")
                if redpanda_bounce
                else None
            ),
            "chaos_redpanda_bounce_after_recovery_reachable": (
                (redpanda_bounce.get("connectivity", {}) or {}).get("after_restart_broker_reachable")
                if redpanda_bounce
                else None
            ),
            "chaos_redpanda_bounce_post_recovery_consume_ok": (
                (redpanda_bounce.get("connectivity", {}) or {}).get("post_restart_consume_ok")
                if redpanda_bounce
                else None
            ),
            "network_partition_runbook_ok": bool(network_partition_runbook.get("runbook_ok")) if network_partition_runbook and network_partition_runbook.get("runbook_ok") is not None else None,
            "network_partition_runbook_budget_ok": bool(network_partition_runbook.get("budget_ok")) if network_partition_runbook and network_partition_runbook.get("budget_ok") is not None else None,
            "network_partition_runbook_method": network_partition_runbook.get("applied_isolation_method") if network_partition_runbook else None,
            "network_partition_runbook_during_reachable": network_partition_runbook.get("during_partition_broker_reachable") if network_partition_runbook else None,
            "network_partition_runbook_recommended_action": network_partition_runbook.get("recommended_action") if network_partition_runbook else None,
            "redpanda_bounce_runbook_ok": bool(redpanda_bounce_runbook.get("runbook_ok")) if redpanda_bounce_runbook and redpanda_bounce_runbook.get("runbook_ok") is not None else None,
            "redpanda_bounce_runbook_budget_ok": bool(redpanda_bounce_runbook.get("budget_ok")) if redpanda_bounce_runbook and redpanda_bounce_runbook.get("budget_ok") is not None else None,
            "redpanda_bounce_runbook_during_reachable": redpanda_bounce_runbook.get("during_stop_broker_reachable") if redpanda_bounce_runbook else None,
            "redpanda_bounce_runbook_after_recovery_reachable": redpanda_bounce_runbook.get("after_restart_broker_reachable") if redpanda_bounce_runbook else None,
            "redpanda_bounce_runbook_post_recovery_consume_ok": redpanda_bounce_runbook.get("post_restart_consume_ok") if redpanda_bounce_runbook else None,
            "redpanda_bounce_runbook_recommended_action": redpanda_bounce_runbook.get("recommended_action") if redpanda_bounce_runbook else None,
            "adversarial_ok": bool(adversarial.get("ok")) if adversarial else None,
            "adversarial_failed_step_count": (
                len([s for s in (adversarial.get("steps", []) or []) if isinstance(s, dict) and s.get("status") == "fail"])
                if adversarial
                else None
            ),
            "adversarial_exactly_once_status": (
                next(
                    (
                        s.get("status")
                        for s in (adversarial.get("steps", []) or [])
                        if isinstance(s, dict) and s.get("name") == "exactly_once_stress"
                    ),
                    None,
                )
                if adversarial
                else None
            ),
            "adversarial_runbook_ok": bool(adversarial_runbook.get("runbook_ok")) if adversarial_runbook and adversarial_runbook.get("runbook_ok") is not None else None,
            "adversarial_runbook_budget_ok": bool(adversarial_runbook.get("budget_ok")) if adversarial_runbook and adversarial_runbook.get("budget_ok") is not None else None,
            "adversarial_runbook_failed_step_count": int(adversarial_runbook.get("failed_step_count")) if adversarial_runbook and adversarial_runbook.get("failed_step_count") is not None else None,
            "adversarial_runbook_skipped_step_count": int(adversarial_runbook.get("skipped_step_count")) if adversarial_runbook and adversarial_runbook.get("skipped_step_count") is not None else None,
            "adversarial_runbook_exactly_once_status": adversarial_runbook.get("exactly_once_status") if adversarial_runbook else None,
            "adversarial_runbook_recommended_action": adversarial_runbook.get("recommended_action") if adversarial_runbook else None,
            "exactly_once_runbook_proof_ok": bool(exactly_once_runbook.get("proof_ok")) if exactly_once_runbook else None,
            "exactly_once_runbook_proof_repeats": int(exactly_once_runbook.get("proof_repeats")) if exactly_once_runbook and exactly_once_runbook.get("proof_repeats") is not None else None,
            "exactly_once_runbook_ok": bool(exactly_once_runbook.get("runbook_ok")) if exactly_once_runbook and exactly_once_runbook.get("runbook_ok") is not None else None,
            "exactly_once_runbook_budget_ok": bool(exactly_once_runbook.get("budget_ok")) if exactly_once_runbook and exactly_once_runbook.get("budget_ok") is not None else None,
            "exactly_once_runbook_recommended_action": exactly_once_runbook.get("recommended_action") if exactly_once_runbook else None,
            "mapping_integrity_runbook_proof_ok": bool(mapping_integrity_runbook.get("proof_ok")) if mapping_integrity_runbook else None,
            "mapping_integrity_runbook_ok": bool(mapping_integrity_runbook.get("runbook_ok")) if mapping_integrity_runbook and mapping_integrity_runbook.get("runbook_ok") is not None else None,
            "mapping_integrity_runbook_budget_ok": bool(mapping_integrity_runbook.get("budget_ok")) if mapping_integrity_runbook and mapping_integrity_runbook.get("budget_ok") is not None else None,
            "mapping_integrity_runbook_recommended_action": mapping_integrity_runbook.get("recommended_action") if mapping_integrity_runbook else None,
            "mapping_coverage_runbook_proof_ok": bool(mapping_coverage_runbook.get("proof_ok")) if mapping_coverage_runbook else None,
            "mapping_coverage_runbook_ok": bool(mapping_coverage_runbook.get("runbook_ok")) if mapping_coverage_runbook and mapping_coverage_runbook.get("runbook_ok") is not None else None,
            "mapping_coverage_runbook_budget_ok": bool(mapping_coverage_runbook.get("budget_ok")) if mapping_coverage_runbook and mapping_coverage_runbook.get("budget_ok") is not None else None,
            "mapping_coverage_runbook_baseline_ok": bool(mapping_coverage_runbook.get("baseline_ok")) if mapping_coverage_runbook else None,
            "mapping_coverage_runbook_strict_probe_exit_code": int(mapping_coverage_runbook.get("strict_probe_exit_code")) if mapping_coverage_runbook and mapping_coverage_runbook.get("strict_probe_exit_code") is not None else None,
            "mapping_coverage_runbook_partial_probe_exit_code": int(mapping_coverage_runbook.get("partial_probe_exit_code")) if mapping_coverage_runbook and mapping_coverage_runbook.get("partial_probe_exit_code") is not None else None,
            "mapping_coverage_runbook_partial_unmapped_enforced_controls_count": int(mapping_coverage_runbook.get("partial_unmapped_enforced_controls_count")) if mapping_coverage_runbook and mapping_coverage_runbook.get("partial_unmapped_enforced_controls_count") is not None else None,
            "mapping_coverage_runbook_recommended_action": mapping_coverage_runbook.get("recommended_action") if mapping_coverage_runbook else None,
            "idempotency_latch_runbook_idempotency_ok": bool(idempotency_latch_runbook.get("idempotency_ok")) if idempotency_latch_runbook else None,
            "idempotency_latch_runbook_latch_ok": bool(idempotency_latch_runbook.get("latch_ok")) if idempotency_latch_runbook else None,
            "idempotency_latch_runbook_ok": bool(idempotency_latch_runbook.get("runbook_ok")) if idempotency_latch_runbook and idempotency_latch_runbook.get("runbook_ok") is not None else None,
            "idempotency_latch_runbook_budget_ok": bool(idempotency_latch_runbook.get("budget_ok")) if idempotency_latch_runbook and idempotency_latch_runbook.get("budget_ok") is not None else None,
            "idempotency_latch_runbook_recommended_action": idempotency_latch_runbook.get("recommended_action") if idempotency_latch_runbook else None,
            "idempotency_key_format_runbook_ok": bool(idempotency_key_format_runbook.get("runbook_ok")) if idempotency_key_format_runbook and idempotency_key_format_runbook.get("runbook_ok") is not None else None,
            "idempotency_key_format_runbook_budget_ok": bool(idempotency_key_format_runbook.get("budget_ok")) if idempotency_key_format_runbook and idempotency_key_format_runbook.get("budget_ok") is not None else None,
            "idempotency_key_format_runbook_proof_ok": bool(idempotency_key_format_runbook.get("proof_ok")) if idempotency_key_format_runbook else None,
            "idempotency_key_format_runbook_missing_tests_count": int(idempotency_key_format_runbook.get("missing_tests_count")) if idempotency_key_format_runbook and idempotency_key_format_runbook.get("missing_tests_count") is not None else None,
            "idempotency_key_format_runbook_failed_tests_count": int(idempotency_key_format_runbook.get("failed_tests_count")) if idempotency_key_format_runbook and idempotency_key_format_runbook.get("failed_tests_count") is not None else None,
            "idempotency_key_format_runbook_recommended_action": idempotency_key_format_runbook.get("recommended_action") if idempotency_key_format_runbook else None,
            "proof_health_runbook_ok": bool(proof_health_runbook.get("runbook_ok")) if proof_health_runbook and proof_health_runbook.get("runbook_ok") is not None else None,
            "proof_health_runbook_budget_ok": bool(proof_health_runbook.get("budget_ok")) if proof_health_runbook and proof_health_runbook.get("budget_ok") is not None else None,
            "proof_health_runbook_proof_ok": bool(proof_health_runbook.get("proof_health_ok")) if proof_health_runbook else None,
            "proof_health_runbook_missing_count": int(proof_health_runbook.get("missing_count")) if proof_health_runbook and proof_health_runbook.get("missing_count") is not None else None,
            "proof_health_runbook_failing_count": int(proof_health_runbook.get("failing_count")) if proof_health_runbook and proof_health_runbook.get("failing_count") is not None else None,
            "proof_health_runbook_recommended_action": proof_health_runbook.get("recommended_action") if proof_health_runbook else None,
            "release_gate_context_runbook_ok": bool(release_gate_context_runbook.get("runbook_ok")) if release_gate_context_runbook and release_gate_context_runbook.get("runbook_ok") is not None else None,
            "release_gate_context_runbook_budget_ok": bool(release_gate_context_runbook.get("budget_ok")) if release_gate_context_runbook and release_gate_context_runbook.get("budget_ok") is not None else None,
            "release_gate_context_runbook_proof_ok": bool(release_gate_context_runbook.get("proof_ok")) if release_gate_context_runbook else None,
            "release_gate_context_runbook_baseline_expected_pass": bool(release_gate_context_runbook.get("baseline_expected_pass")) if release_gate_context_runbook and release_gate_context_runbook.get("baseline_expected_pass") is not None else None,
            "release_gate_context_runbook_failure_probe_expected_fail": bool(release_gate_context_runbook.get("failure_probe_expected_fail")) if release_gate_context_runbook and release_gate_context_runbook.get("failure_probe_expected_fail") is not None else None,
            "release_gate_context_runbook_failure_probe_failed_checks_count": int(release_gate_context_runbook.get("failure_probe_failed_checks_count")) if release_gate_context_runbook and release_gate_context_runbook.get("failure_probe_failed_checks_count") is not None else None,
            "release_gate_context_runbook_failure_fallback_expected_fail": bool(release_gate_context_runbook.get("failure_fallback_expected_fail")) if release_gate_context_runbook and release_gate_context_runbook.get("failure_fallback_expected_fail") is not None else None,
            "release_gate_context_runbook_failure_fallback_missing_fields_count": int(release_gate_context_runbook.get("failure_fallback_missing_fields_count")) if release_gate_context_runbook and release_gate_context_runbook.get("failure_fallback_missing_fields_count") is not None else None,
            "release_gate_context_runbook_recommended_action": release_gate_context_runbook.get("recommended_action") if release_gate_context_runbook else None,
            "proof_health_ok": bool(proof_health.get("ok")) if proof_health else None,
            "proof_health_health_ok": bool(proof_health.get("health_ok")) if proof_health else None,
            "proof_health_missing_count": int(proof_health.get("missing_count")) if proof_health and proof_health.get("missing_count") is not None else None,
            "proof_health_failing_count": int(proof_health.get("failing_count")) if proof_health and proof_health.get("failing_count") is not None else None,
            "release_gate_ok": bool(release_gate.get("ok")) if release_gate else None,
            "release_gate_runbook_context_backfill_ok": bool(release_gate.get("runbook_context_backfill_ok")) if release_gate and release_gate.get("runbook_context_backfill_ok") is not None else None,
            "release_gate_runbook_context_missing_count": len((release_gate.get("runbook_context_missing", []) or [])) if release_gate else None,
            "release_gate_fallback_smoke_ok": bool(release_gate_fallback_smoke.get("ok")) if release_gate_fallback_smoke else None,
            "release_gate_fallback_smoke_used_embedded_check": bool(release_gate_fallback_smoke.get("used_release_gate_embedded_check")) if release_gate_fallback_smoke and release_gate_fallback_smoke.get("used_release_gate_embedded_check") is not None else None,
            "release_gate_fallback_smoke_missing_fields_count": len((release_gate_fallback_smoke.get("missing_fields", []) or [])) if release_gate_fallback_smoke else None,
            "controls_freshness_proof_ok": bool(controls_freshness.get("ok")) if controls_freshness else None,
            "budget_freshness_proof_ok": bool(budget_freshness.get("ok")) if budget_freshness else None,
        },
    },
    "pii_scan": {
        "passed": len(pii_hits) == 0,
        "hits": pii_hits,
    },
    "sources": {
        "load": "build/load/load-smoke.json",
        "dr": "build/dr/dr-report.json",
        "invariants": "build/invariants/ledger-invariants.json",
        "core_invariants": "build/invariants/core-invariants.json",
        "invariants_summary": "build/invariants/invariants-summary.json",
        "determinism": "build/determinism/prove-determinism-latest.json",
        "idempotency_scope": "build/idempotency/prove-idempotency-latest.json",
        "idempotency_key_format": "build/idempotency/prove-idempotency-key-format-latest.json",
        "latch_approval": "build/latch/prove-latch-approval-latest.json",
        "exactly_once_million": "build/exactly-once/prove-exactly-once-million-latest.json",
        "ws": "build/ws/ws-smoke.json",
        "ws_resume": "build/ws/ws-resume-smoke.json",
        "safety_budget": "build/safety/safety-budget-latest.json",
        "snapshot_verify": "build/snapshot/snapshot-verify-latest.json",
        "controls": "build/controls/controls-check-latest.json",
        "controls_freshness": "build/controls/prove-controls-freshness-latest.json",
        "compliance": "build/compliance/compliance-evidence-latest.json",
        "mapping_integrity": "build/compliance/prove-mapping-integrity-latest.json",
        "mapping_coverage": "build/compliance/prove-mapping-coverage-latest.json",
        "mapping_coverage_metrics": "build/metrics/mapping-coverage-latest.json",
        "audit_chain": "build/audit/verify-audit-chain-latest.json",
        "change_audit_chain": "build/change-audit/verify-change-audit-chain-latest.json",
        "pii_log_scan": "build/security/pii-log-scan-latest.json",
        "rbac_sod": "build/security/rbac-sod-check-latest.json",
        "anomaly": "build/anomaly/anomaly-detector-latest.json",
        "budget_freshness": "build/safety/prove-budget-freshness-latest.json",
        "proof_health": "build/metrics/proof-health-latest.json",
        "release_gate": "build/release-gate/release-gate-latest.json",
        "release_gate_fallback_smoke": "build/release-gate-smoke/release-gate-fallback-smoke-latest.json",
        "release_gate_context_proof": "build/release-gate/prove-release-gate-context-latest.json",
        "policy_smoke": "build/policy-smoke/policy-smoke-latest.json",
        "policy_tamper": "build/policy/prove-policy-tamper-latest.json",
        "network_partition": "build/chaos/network-partition-latest.json",
        "redpanda_bounce": "build/chaos/redpanda-broker-bounce-latest.json",
        "adversarial": "build/adversarial/adversarial-tests-latest.json",
        "policy_signature_runbook": "build/runbooks/policy-signature-latest.json",
        "policy_tamper_runbook": "build/runbooks/policy-tamper-latest.json",
        "network_partition_runbook": "build/runbooks/network-partition-latest.json",
        "redpanda_bounce_runbook": "build/runbooks/redpanda-broker-bounce-latest.json",
        "adversarial_runbook": "build/runbooks/adversarial-reliability-latest.json",
        "exactly_once_runbook": "build/runbooks/exactly-once-million-latest.json",
        "mapping_integrity_runbook": "build/runbooks/mapping-integrity-latest.json",
        "mapping_coverage_runbook": "build/runbooks/mapping-coverage-latest.json",
        "idempotency_latch_runbook": "build/runbooks/idempotency-latch-latest.json",
        "idempotency_key_format_runbook": "build/runbooks/idempotency-key-format-latest.json",
        "proof_health_runbook": "build/runbooks/proof-health-latest.json",
        "release_gate_context_runbook": "build/runbooks/release-gate-context-latest.json",
    },
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

REPORT_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "transparency_report_file=${REPORT_FILE}"
echo "transparency_report_latest=${LATEST_FILE}"
echo "transparency_report_ok=${REPORT_OK}"

if [[ "${REPORT_OK}" != "true" ]]; then
  exit 1
fi
