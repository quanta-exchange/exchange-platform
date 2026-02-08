#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build/security"
OUT_FILE="$OUT_DIR/rotation-drill.json"
mkdir -p "$OUT_DIR"

# Simulated rotation drill metadata. In production this should be sourced from secret manager APIs.
NOW_EPOCH="$(date +%s)"
LAST_ROTATION_EPOCH="${LAST_ROTATION_EPOCH:-$((NOW_EPOCH - 3600))}"
MAX_AGE_SECONDS="${MAX_AGE_SECONDS:-2592000}" # 30 days
ROTATION_AGE="$((NOW_EPOCH - LAST_ROTATION_EPOCH))"

STATUS="pass"
if (( ROTATION_AGE > MAX_AGE_SECONDS )); then
  STATUS="fail"
fi

cat > "$OUT_FILE" <<JSON
{
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "secret_access_audit_total": 1,
  "rotation_age_seconds": $ROTATION_AGE,
  "max_age_seconds": $MAX_AGE_SECONDS,
  "status": "$STATUS"
}
JSON

cat "$OUT_FILE"
if [[ "$STATUS" != "pass" ]]; then
  exit 1
fi
