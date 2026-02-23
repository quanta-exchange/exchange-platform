doctor:
	./scripts/doctor.sh

.PHONY: doctor load-smoke dr-rehearsal invariants safety-case safety-case-extended safety-case-upload assurance-pack controls-check verification-factory release-gate safety-budget compliance-evidence transparency-report external-replay-demo archive-range verify-archive policy-sign policy-verify policy-smoke adversarial-tests prove-determinism change-proposal change-approve apply-change break-glass-enable break-glass-disable break-glass-status access-review runbook-lag-spike runbook-ws-drop exactly-once-stress chaos-full chaos-core chaos-ledger chaos-redpanda

load-smoke:
	./scripts/load_smoke.sh

dr-rehearsal:
	./scripts/dr_rehearsal.sh

invariants:
	./scripts/invariants.sh

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

runbook-lag-spike:
	./runbooks/lag_spike.sh

runbook-ws-drop:
	./runbooks/ws_drop_spike.sh

exactly-once-stress:
	./scripts/exactly_once_stress.sh

chaos-full:
	./scripts/chaos/full_replay.sh

chaos-core:
	./scripts/chaos/core_kill_recover.sh

chaos-ledger:
	./scripts/chaos/ledger_kill_recover.sh

chaos-redpanda:
	./scripts/chaos/redpanda_broker_bounce.sh
