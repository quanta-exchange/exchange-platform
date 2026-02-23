# Runbook: Mapping Integrity Failure

## Purpose
- Reproduce and diagnose compliance mapping integrity regressions.
- Validate duplicate-mapping detection path and baseline mapping health.
- Capture before/after system snapshots and deterministic summary evidence.

## Command
```bash
make runbook-mapping-integrity
# or
./runbooks/mapping_integrity_failure.sh
```

## Optional env
- `RUNBOOK_ALLOW_PROOF_FAIL=true` (collect evidence without failing runbook)
- `RUNBOOK_ALLOW_BUDGET_FAIL=true` (allow unrelated budget violations during diagnosis)

## Outputs
- `runbook_mapping_integrity_ok=true|false`
- `mapping_integrity_proof_ok=true|false`
- `mapping_integrity_duplicate_probe_exit_code=<code>`
- `mapping_integrity_duplicate_mapping_ids_count=<n>`
- `mapping_integrity_baseline_probe_exit_code=<code>`
- `mapping_integrity_baseline_duplicate_mapping_ids_count=<n>`
- `mapping_integrity_recommended_action=...`
- `mapping_integrity_summary_file=build/runbooks/mapping-integrity-<timestamp>/mapping-integrity-summary.json`
- `mapping_integrity_summary_latest=build/runbooks/mapping-integrity-latest.json`
- `runbook_output_dir=build/runbooks/mapping-integrity-<timestamp>`

## Recommended actions
- `INVESTIGATE_DUPLICATE_MAPPING_GUARD`
- `INVESTIGATE_BASELINE_MAPPING`
- `INVESTIGATE_MAPPING_INTEGRITY_PROOF`
- `RUN_BUDGET_FAILURE_RUNBOOK`
- `NO_ACTION`
