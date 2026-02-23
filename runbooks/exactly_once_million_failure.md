# Runbook: Exactly-Once Million Duplicate Failure

## Purpose
- Reproduce and diagnose failure of the million-duplicate exactly-once proof.
- Capture before/after system status and a deterministic summary artifact.

## Command
```bash
make runbook-exactly-once-million
# or
./runbooks/exactly_once_million_failure.sh
```

## Optional env
- `RUNBOOK_REPEATS` (default: `1000000`)
- `RUNBOOK_CONCURRENCY` (default: `64`)
- `RUNBOOK_ALLOW_PROOF_FAIL=true` (keep runbook green while collecting evidence)
- `RUNBOOK_ALLOW_BUDGET_FAIL=true` (allow non-blocking safety-budget failures)

## Outputs
- `runbook_exactly_once_million_ok=true|false`
- `exactly_once_million_proof_ok=true|false`
- `exactly_once_million_proof_repeats=<n>`
- `exactly_once_million_proof_concurrency=<n>`
- `exactly_once_million_proof_runner_exit_code=<code>`
- `exactly_once_million_recommended_action=...`
- `runbook_output_dir=build/runbooks/exactly-once-million-<timestamp>`

## Recommended actions
- `INCREASE_REPEATS_TO_MILLION_AND_RERUN`
- `INVESTIGATE_EXACTLY_ONCE_PATH`
- `RUN_BUDGET_FAILURE_RUNBOOK`
- `NO_ACTION`
