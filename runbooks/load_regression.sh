#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/load-regression-${TS_ID}}"
LOG_FILE="$OUT_DIR/load-regression.log"

mkdir -p "$OUT_DIR"

{
  echo "runbook=load_regression"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true
  OUT_DIR="$OUT_DIR" "$ROOT_DIR/scripts/load_all.sh"
  if "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"; then
    echo "runbook_budget_ok=true"
  else
    echo "runbook_budget_ok=false"
    if [[ "${RUNBOOK_ALLOW_BUDGET_FAIL:-false}" != "true" ]]; then
      exit 1
    fi
  fi
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  echo "runbook_load_regression_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
