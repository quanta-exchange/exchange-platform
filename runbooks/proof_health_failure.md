# Runbook: Proof Health Failure

## Purpose
- Reproduce and diagnose proof/runbook artifact health failures from a single command.
- Capture deterministic summary evidence for release/status/governance contexts.

## Command
```bash
make runbook-proof-health
# or
./runbooks/proof_health_failure.sh
```

## Optional env
- `RUNBOOK_ALLOW_PROOF_FAIL=true` (collect diagnostics without failing runbook)
- `RUNBOOK_ALLOW_BUDGET_FAIL=true` (allow unrelated safety-budget violations)

## Outputs
- `runbook_proof_health_ok=true|false`
- `runbook_budget_ok=true|false`
- `proof_health_runbook_proof_ok=true|false`
- `proof_health_runbook_tracked_count=<n>`
- `proof_health_runbook_present_count=<n>`
- `proof_health_runbook_missing_count=<n>`
- `proof_health_runbook_failing_count=<n>`
- `proof_health_runbook_missing_artifacts=...`
- `proof_health_runbook_failing_artifacts=...`
- `proof_health_runbook_recommended_action=...`
- `proof_health_summary_file=build/runbooks/proof-health-<timestamp>/proof-health-summary.json`
- `proof_health_summary_latest=build/runbooks/proof-health-latest.json`
- `runbook_output_dir=build/runbooks/proof-health-<timestamp>`

## Recommended actions
- `INVESTIGATE_PROOF_HEALTH_EXPORTER`
- `RESTORE_MISSING_PROOF_ARTIFACTS`
- `INVESTIGATE_FAILING_PROOFS`
- `RUN_BUDGET_FAILURE_RUNBOOK`
- `NO_ACTION`
