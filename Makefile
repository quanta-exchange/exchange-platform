doctor:
	./scripts/doctor.sh

.PHONY: doctor load-smoke dr-rehearsal safety-case safety-case-upload

load-smoke:
	./scripts/load_smoke.sh

dr-rehearsal:
	./scripts/dr_rehearsal.sh

safety-case:
	./scripts/safety_case.sh --run-checks

safety-case-upload:
	./scripts/safety_case.sh --run-checks --upload-minio
