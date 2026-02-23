#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/game-day-anomaly-${TS_ID}}"
LOG_FILE="$OUT_DIR/game-day-anomaly.log"
WEBHOOK_URL="${WEBHOOK_URL:-}"

mkdir -p "$OUT_DIR"

{
  echo "runbook=game_day_anomaly"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true
  if [[ -n "$WEBHOOK_URL" ]]; then
    OUT_DIR="$OUT_DIR" "$ROOT_DIR/scripts/anomaly_detector.sh" \
      --force-anomaly \
      --allow-anomaly \
      --webhook-url "$WEBHOOK_URL"
  else
    OUT_DIR="$OUT_DIR" "$ROOT_DIR/scripts/anomaly_detector.sh" \
      --force-anomaly \
      --allow-anomaly
  fi
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR" || true
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  echo "runbook_game_day_anomaly_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
