# Runbook: crash_recovery

Purpose:
- rehearse abrupt core/ledger failure and deterministic recovery
- validate snapshot+WAL restore path and post-recovery safety budget

Command:
- `./runbooks/crash_recovery.sh`
  - default: `CHAOS_SKIP_LEDGER_ASSERTS=true` (faster drill while still proving core/hash recovery path)
  - strict ledger row-count assertions: `CHAOS_SKIP_LEDGER_ASSERTS=false ./runbooks/crash_recovery.sh`

Outputs:
- `build/runbooks/crash-recovery-<timestamp>/snapshot-verify.json`
- `build/runbooks/crash-recovery-<timestamp>/chaos-replay.json`
- `build/runbooks/crash-recovery-<timestamp>/safety-budget-*.json`
- `build/runbooks/crash-recovery-<timestamp>/status-before.json`
- `build/runbooks/crash-recovery-<timestamp>/status-after.json`

Success markers:
- `runbook_crash_recovery_ok=true`
- `chaos_replay_success=true`
- `snapshot_verify_ok=true`
