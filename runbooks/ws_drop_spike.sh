#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/ws-drop-spike-${TS_ID}}"
LOG_FILE="$OUT_DIR/ws-drop-spike.log"

mkdir -p "$OUT_DIR"

{
  echo "runbook=ws_drop_spike"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true
  OUT_DIR="$OUT_DIR" REPORT_FILE="$OUT_DIR/ws-smoke.json" "$ROOT_DIR/scripts/ws_smoke.sh"
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  echo "runbook_ws_drop_spike_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
