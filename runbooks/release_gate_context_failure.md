# Runbook: Release-Gate Context Failure

## Purpose
- Reproduce and diagnose release-gate runbook-context/fallback proof regressions.
- Verify baseline pass + tampered-input fail behavior with deterministic summary evidence.

## Command
```bash
make runbook-release-gate-context
# or
./runbooks/release_gate_context_failure.sh
```

## Optional env
- `RUNBOOK_REQUIRE_RUNBOOK_CONTEXT=true|false` (default: `true`)
- `RUNBOOK_ALLOW_PROOF_FAIL=true` (collect diagnostics without failing runbook)
- `RUNBOOK_ALLOW_BUDGET_FAIL=true` (allow unrelated safety-budget violations)

## Outputs
- `runbook_release_gate_context_ok=true|false`
- `runbook_budget_ok=true|false`
- `release_gate_context_baseline_proof_ok=true|false`
- `release_gate_context_baseline_fallback_ok=true|false`
- `release_gate_context_failure_probe_exit_code=<code>`
- `release_gate_context_failure_probe_ok=true|false`
- `release_gate_context_failure_probe_failed_checks_count=<n>`
- `release_gate_context_failure_fallback_exit_code=<code>`
- `release_gate_context_failure_fallback_ok=true|false`
- `release_gate_context_failure_fallback_missing_fields_count=<n>`
- `release_gate_context_proof_ok=true|false`
- `release_gate_context_recommended_action=...`
- `release_gate_context_summary_file=build/runbooks/release-gate-context-<timestamp>/release-gate-context-summary.json`
- `release_gate_context_summary_latest=build/runbooks/release-gate-context-latest.json`
- `runbook_output_dir=build/runbooks/release-gate-context-<timestamp>`

## Recommended actions
- `INVESTIGATE_RELEASE_GATE_CONTEXT_BASELINE`
- `INVESTIGATE_RELEASE_GATE_CONTEXT_PROOF_ENFORCEMENT`
- `INVESTIGATE_RELEASE_GATE_FALLBACK_SMOKE_ENFORCEMENT`
- `RUN_BUDGET_FAILURE_RUNBOOK`
- `NO_ACTION`
