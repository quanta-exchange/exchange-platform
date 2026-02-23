doctor:
	./scripts/doctor.sh

.PHONY: doctor load-smoke dr-rehearsal invariants safety-case safety-case-extended safety-case-upload assurance-pack controls-check verification-factory safety-budget compliance-evidence transparency-report policy-sign policy-verify policy-smoke runbook-lag-spike runbook-ws-drop exactly-once-stress chaos-full chaos-core chaos-ledger chaos-redpanda

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

safety-budget:
	./scripts/safety_budget_check.sh

compliance-evidence:
	./scripts/compliance_evidence.sh

transparency-report:
	./scripts/transparency_report.sh

policy-sign:
	./scripts/policy_sign.sh

policy-verify:
	./scripts/policy_verify.sh

policy-smoke:
	./scripts/policy_smoke.sh

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
