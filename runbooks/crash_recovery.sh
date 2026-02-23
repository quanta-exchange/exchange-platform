#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/crash-recovery-${TS_ID}}"
LOG_FILE="$OUT_DIR/crash-recovery.log"
CHAOS_SKIP_LEDGER_ASSERTS="${CHAOS_SKIP_LEDGER_ASSERTS:-true}"

mkdir -p "$OUT_DIR"

{
  echo "runbook=crash_recovery"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true
  OUT_DIR="$OUT_DIR" REPORT_FILE="$OUT_DIR/snapshot-verify.json" "$ROOT_DIR/scripts/snapshot_verify.sh"
  CHAOS_SKIP_LEDGER_ASSERTS="$CHAOS_SKIP_LEDGER_ASSERTS" \
    OUT_DIR="$OUT_DIR" REPORT_FILE="$OUT_DIR/chaos-replay.json" \
    "$ROOT_DIR/scripts/chaos/full_replay.sh"
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  echo "runbook_crash_recovery_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
