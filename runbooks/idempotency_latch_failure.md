# Runbook: Idempotency + Latch Failure

## Purpose
- Reproduce and diagnose idempotency-scope proof and latch-approval proof failures.
- Capture deterministic summary evidence for release/status/governance contexts.

## Command
```bash
make runbook-idempotency-latch
# or
./runbooks/idempotency_latch_failure.sh
```

## Optional env
- `RUNBOOK_ALLOW_PROOF_FAIL=true` (collect diagnostics without failing runbook)
- `RUNBOOK_ALLOW_BUDGET_FAIL=true` (allow unrelated safety-budget violations)

## Outputs
- `runbook_idempotency_latch_ok=true|false`
- `runbook_budget_ok=true|false`
- `idempotency_scope_proof_ok=true|false`
- `idempotency_scope_proof_passed=<n>`
- `idempotency_scope_proof_failed=<n>`
- `latch_approval_proof_ok=true|false`
- `latch_approval_missing_tests_count=<n>`
- `latch_approval_failed_tests_count=<n>`
- `idempotency_latch_recommended_action=...`
- `idempotency_latch_summary_file=build/runbooks/idempotency-latch-<timestamp>/idempotency-latch-summary.json`
- `idempotency_latch_summary_latest=build/runbooks/idempotency-latch-latest.json`
- `runbook_output_dir=build/runbooks/idempotency-latch-<timestamp>`

## Recommended actions
- `INVESTIGATE_IDEMPOTENCY_SCOPE`
- `INVESTIGATE_LATCH_APPROVAL`
- `RUN_BUDGET_FAILURE_RUNBOOK`
- `NO_ACTION`
