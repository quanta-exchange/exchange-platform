# Idempotency-Key format failure drill

## Purpose
- verify malformed `Idempotency-Key` rejection/normalization proof remains executable
- capture deterministic remediation guidance when proof or budget checks fail

## Command
```bash
./runbooks/idempotency_key_format_failure.sh
```

## Optional flags
- allow proof failure without failing runbook:
  - `RUNBOOK_ALLOW_PROOF_FAIL=true ./runbooks/idempotency_key_format_failure.sh`
- allow safety-budget failure without failing runbook:
  - `RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/idempotency_key_format_failure.sh`

## Expected outputs
- `runbook_idempotency_key_format_ok=true|false`
- `idempotency_key_format_proof_ok=true|false`
- `idempotency_key_format_missing_tests_count=<n>`
- `idempotency_key_format_failed_tests_count=<n>`
- `idempotency_key_format_recommended_action=...`
- `idempotency_key_format_summary_file=build/runbooks/idempotency-key-format-<timestamp>/idempotency-key-format-summary.json`
- `idempotency_key_format_summary_latest=build/runbooks/idempotency-key-format-latest.json`
