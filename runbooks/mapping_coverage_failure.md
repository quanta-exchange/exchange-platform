# Runbook: Mapping Coverage Failure

## Purpose
- Reproduce and diagnose controls↔mapping coverage regressions.
- Verify strict(full) coverage mode rejects unmapped controls while partial mode allows unmapped non-enforced controls.
- Capture deterministic summary evidence for release/status/governance contexts.

## Command
```bash
make runbook-mapping-coverage
# or
./runbooks/mapping_coverage_failure.sh
```

## Optional env
- `RUNBOOK_ALLOW_PROOF_FAIL=true` (collect diagnostics without failing runbook)
- `RUNBOOK_ALLOW_BUDGET_FAIL=true` (allow unrelated safety-budget violations)

## Outputs
- `runbook_mapping_coverage_ok=true|false`
- `mapping_coverage_baseline_ok=true|false`
- `mapping_coverage_strict_probe_exit_code=<code>`
- `mapping_coverage_strict_unmapped_controls_count=<n>`
- `mapping_coverage_partial_probe_exit_code=<code>`
- `mapping_coverage_partial_unmapped_controls_count=<n>`
- `mapping_coverage_partial_unmapped_enforced_controls_count=<n>`
- `mapping_coverage_proof_ok=true|false`
- `mapping_coverage_recommended_action=...`
- `mapping_coverage_summary_file=build/runbooks/mapping-coverage-<timestamp>/mapping-coverage-summary.json`
- `mapping_coverage_summary_latest=build/runbooks/mapping-coverage-latest.json`
- `runbook_output_dir=build/runbooks/mapping-coverage-<timestamp>`

## Recommended actions
- `INVESTIGATE_BASELINE_MAPPING_COVERAGE`
- `INVESTIGATE_FULL_COVERAGE_ENFORCEMENT`
- `INVESTIGATE_PARTIAL_COVERAGE_MODE`
- `INVESTIGATE_ENFORCED_MAPPING_GUARD`
- `RUN_BUDGET_FAILURE_RUNBOOK`
- `NO_ACTION`
