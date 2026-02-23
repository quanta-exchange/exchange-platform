#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/lag-spike-${TS_ID}}"
LOG_FILE="$OUT_DIR/lag-spike.log"

mkdir -p "$OUT_DIR"

{
  echo "runbook=lag_spike"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  OUT_DIR="$OUT_DIR" REPORT_FILE="$OUT_DIR/reconciliation-smoke.json" "$ROOT_DIR/scripts/smoke_reconciliation_safety.sh"
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"
  echo "runbook_lag_spike_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
