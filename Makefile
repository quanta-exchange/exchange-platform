doctor:
	./scripts/doctor.sh

.PHONY: doctor load-smoke load-10k load-50k load-all dr-rehearsal invariants snapshot-verify safety-case safety-case-extended safety-case-upload assurance-pack controls-check verification-factory release-gate safety-budget compliance-evidence transparency-report external-replay-demo archive-range verify-archive verify-audit-chain verify-change-audit-chain pii-log-scan anomaly-detector anomaly-smoke rbac-sod-check policy-sign policy-verify policy-smoke adversarial-tests prove-determinism prove-idempotency prove-latch-approval prove-breakers prove-candles prove-budget-freshness prove-controls-freshness prove-exactly-once-million prove-mapping-integrity prove-policy-tamper verify-service-modes model-check shadow-verify system-status change-proposal change-approve apply-change break-glass-enable break-glass-disable break-glass-status access-review runbook-lag-spike runbook-ws-drop runbook-ws-resume-gap runbook-load-regression runbook-crash-recovery runbook-startup-guardrails runbook-game-day-anomaly runbook-audit-tamper runbook-change-workflow runbook-budget-failure runbook-exactly-once-million runbook-mapping-integrity runbook-adversarial-reliability runbook-policy-signature runbook-policy-tamper runbook-network-partition runbook-redpanda-bounce exactly-once-stress ws-resume-smoke chaos-full chaos-core chaos-ledger chaos-redpanda chaos-network-partition

load-smoke:
	./scripts/load_smoke.sh

load-10k:
	./scripts/load_10k.sh

load-50k:
	./scripts/load_50k.sh

load-all:
	./scripts/load_all.sh

dr-rehearsal:
	./scripts/dr_rehearsal.sh

invariants:
	./scripts/invariants.sh

snapshot-verify:
	./scripts/snapshot_verify.sh

safety-case:
	./scripts/safety_case.sh --run-checks

safety-case-extended:
	./scripts/safety_case.sh --run-checks --run-extended-checks

safety-case-upload:
	./scripts/safety_case.sh --run-checks --upload-minio

assurance-pack:
	./scripts/assurance_pack.sh

controls-check:
	./scripts/controls_check.sh

verification-factory:
	./scripts/verification_factory.sh

release-gate:
	./scripts/release_gate.sh

safety-budget:
	./scripts/safety_budget_check.sh

compliance-evidence:
	./scripts/compliance_evidence.sh

transparency-report:
	./scripts/transparency_report.sh

external-replay-demo:
	./tools/external-replay/external_replay_demo.sh

archive-range:
	@echo "usage: ./scripts/archive_range.sh --topic <topic> --from <offset|start|end> --count <n>"

verify-archive:
	@echo "usage: ./scripts/verify_archive.sh --manifest build/archive/<timestamp>/manifest.json"

verify-audit-chain:
	./scripts/verify_audit_chain.sh

verify-change-audit-chain:
	./scripts/verify_change_audit_chain.sh

pii-log-scan:
	./scripts/pii_log_scan.sh

anomaly-detector:
	./scripts/anomaly_detector.sh

anomaly-smoke:
	./scripts/anomaly_detector_smoke.sh

rbac-sod-check:
	./scripts/rbac_sod_check.sh

policy-sign:
	./scripts/policy_sign.sh

policy-verify:
	./scripts/policy_verify.sh

policy-smoke:
	./scripts/policy_smoke.sh

adversarial-tests:
	./scripts/adversarial_tests.sh

prove-determinism:
	./scripts/prove_determinism.sh

prove-idempotency:
	./scripts/prove_idempotency_scope.sh

prove-latch-approval:
	./scripts/prove_latch_approval.sh

prove-breakers:
	./scripts/prove_breakers.sh

prove-candles:
	./scripts/prove_candles.sh

prove-budget-freshness:
	./scripts/prove_budget_freshness.sh

prove-controls-freshness:
	./scripts/prove_controls_freshness.sh

prove-exactly-once-million:
	./scripts/prove_exactly_once_million.sh

prove-mapping-integrity:
	./scripts/prove_mapping_integrity.sh

prove-policy-tamper:
	./scripts/prove_policy_tamper.sh

verify-service-modes:
	./scripts/verify_service_modes.sh

model-check:
	./scripts/model_check.sh

shadow-verify:
	./scripts/shadow_verify.sh

change-proposal:
	./scripts/change_proposal.sh --title "default change" --requested-by "ops"

change-approve:
	@echo "usage: ./scripts/change_approve.sh --change-dir changes/requests/<id> --approver <name> [--note ...]"

apply-change:
	@echo "usage: ./scripts/apply_change.sh --change-dir changes/requests/<id> --command '...'"

break-glass-enable:
	./scripts/break_glass.sh enable --actor ops --reason emergency

break-glass-disable:
	./scripts/break_glass.sh disable --actor ops --reason resolved

break-glass-status:
	./scripts/break_glass.sh status

access-review:
	./scripts/access_review.sh

system-status:
	./scripts/system_status.sh

runbook-lag-spike:
	./runbooks/lag_spike.sh

runbook-ws-drop:
	./runbooks/ws_drop_spike.sh

runbook-ws-resume-gap:
	./runbooks/ws_resume_gap_spike.sh

runbook-load-regression:
	./runbooks/load_regression.sh

runbook-crash-recovery:
	./runbooks/crash_recovery.sh

runbook-startup-guardrails:
	./runbooks/startup_guardrails.sh

runbook-game-day-anomaly:
	./runbooks/game_day_anomaly.sh

runbook-audit-tamper:
	./runbooks/audit_chain_tamper.sh

runbook-change-workflow:
	./runbooks/change_workflow.sh

runbook-budget-failure:
	./runbooks/budget_failure.sh

runbook-exactly-once-million:
	./runbooks/exactly_once_million_failure.sh

runbook-mapping-integrity:
	./runbooks/mapping_integrity_failure.sh

runbook-adversarial-reliability:
	./runbooks/adversarial_reliability.sh

runbook-policy-signature:
	./runbooks/policy_signature.sh

runbook-policy-tamper:
	./runbooks/policy_tamper.sh

runbook-network-partition:
	./runbooks/network_partition.sh

runbook-redpanda-bounce:
	./runbooks/redpanda_broker_bounce.sh

exactly-once-stress:
	./scripts/exactly_once_stress.sh

ws-resume-smoke:
	./scripts/ws_resume_smoke.sh

chaos-full:
	./scripts/chaos/full_replay.sh

chaos-core:
	./scripts/chaos/core_kill_recover.sh

chaos-ledger:
	./scripts/chaos/ledger_kill_recover.sh

chaos-redpanda:
	./scripts/chaos/redpanda_broker_bounce.sh

chaos-network-partition:
	./scripts/chaos/network_partition.sh
