#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/load}"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_DIR="$OUT_DIR/load-all-logs-${TS_ID}"
REPORT_FILE="$OUT_DIR/load-all-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/load-all-latest.json"

mkdir -p "$LOG_DIR"

run_step() {
  local step="$1"
  shift
  local logfile="$LOG_DIR/${step}.log"
  if "$@" >"$logfile" 2>&1; then
    echo "${step}=pass"
    return 0
  fi
  echo "${step}=fail"
  return 1
}

extract_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | tail -n 1 | sed "s/^${key}=//"
}

status_smoke="fail"
status_10k="fail"
status_50k="fail"
ok=true

if run_step "load-smoke" "$ROOT_DIR/scripts/load_smoke.sh"; then
  status_smoke="pass"
else
  ok=false
fi

if run_step "load-10k" "$ROOT_DIR/scripts/load_10k.sh"; then
  status_10k="pass"
else
  ok=false
fi

if run_step "load-50k" "$ROOT_DIR/scripts/load_50k.sh"; then
  status_50k="pass"
else
  ok=false
fi

SMOKE_LOG="$LOG_DIR/load-smoke.log"
LOAD_10K_LOG="$LOG_DIR/load-10k.log"
LOAD_50K_LOG="$LOG_DIR/load-50k.log"

SMOKE_REPORT="$(extract_value "load_smoke_report" "$SMOKE_LOG")"
PROFILE_10K_REPORT="$(extract_value "load_10k_report" "$LOAD_10K_LOG")"
PROFILE_50K_REPORT="$(extract_value "load_50k_report" "$LOAD_50K_LOG")"

python3 - "$REPORT_FILE" "$status_smoke" "$status_10k" "$status_50k" "$SMOKE_REPORT" "$PROFILE_10K_REPORT" "$PROFILE_50K_REPORT" "$LOG_DIR" <<'PY'
import json
import sys
from datetime import datetime, timezone

report_file = sys.argv[1]
status_smoke = sys.argv[2]
status_10k = sys.argv[3]
status_50k = sys.argv[4]
smoke_report = sys.argv[5]
profile_10k_report = sys.argv[6]
profile_50k_report = sys.argv[7]
log_dir = sys.argv[8]

ok = status_smoke == "pass" and status_10k == "pass" and status_50k == "pass"

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "profiles": [
        {"name": "load-smoke", "status": status_smoke, "report": smoke_report or None},
        {"name": "load-10k", "status": status_10k, "report": profile_10k_report or None},
        {"name": "load-50k", "status": status_50k, "report": profile_50k_report or None},
    ],
    "logs_dir": log_dir,
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "load_all_report=${REPORT_FILE}"
echo "load_all_latest=${LATEST_FILE}"
echo "load_all_ok=${ok}"

if [[ "$ok" != "true" ]]; then
  exit 1
fi
