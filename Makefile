doctor:
	./scripts/doctor.sh

.PHONY: doctor load-smoke dr-rehearsal safety-case safety-case-upload exactly-once-stress

load-smoke:
	./scripts/load_smoke.sh

dr-rehearsal:
	./scripts/dr_rehearsal.sh

safety-case:
	./scripts/safety_case.sh --run-checks

safety-case-upload:
	./scripts/safety_case.sh --run-checks --upload-minio

exactly-once-stress:
	./scripts/exactly_once_stress.sh
