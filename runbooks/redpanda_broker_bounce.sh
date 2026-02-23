#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/redpanda-broker-bounce-${TS_ID}}"
LOG_FILE="$OUT_DIR/redpanda-broker-bounce.log"
CHAOS_OUT_DIR="$OUT_DIR/chaos"

RUNBOOK_ALLOW_REDPANDA_BOUNCE_FAIL="${RUNBOOK_ALLOW_REDPANDA_BOUNCE_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=redpanda_broker_bounce"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  CHAOS_OUTPUT="$(
    OUT_DIR="$CHAOS_OUT_DIR" "$ROOT_DIR/scripts/chaos/redpanda_broker_bounce.sh" 2>&1
  )"
  CHAOS_CODE=$?
  set -e
  echo "$CHAOS_OUTPUT"

  CHAOS_OK="$(extract_value "redpanda_broker_bounce_success" "$CHAOS_OUTPUT")"
  CHAOS_REPORT="$(extract_value "redpanda_broker_bounce_latest" "$CHAOS_OUTPUT")"
  DURING_REACHABLE="$(extract_value "redpanda_broker_bounce_during_reachable" "$CHAOS_OUTPUT")"
  RECOVERED="$(extract_value "redpanda_broker_bounce_recovered" "$CHAOS_OUTPUT")"

  if [[ -z "$CHAOS_REPORT" ]]; then
    CHAOS_REPORT="$CHAOS_OUT_DIR/redpanda-broker-bounce-latest.json"
  fi
  if [[ -z "$CHAOS_OK" ]]; then
    if [[ "$CHAOS_CODE" -eq 0 ]]; then
      CHAOS_OK="true"
    else
      CHAOS_OK="false"
    fi
  fi
  if [[ -z "$DURING_REACHABLE" ]]; then
    DURING_REACHABLE="unknown"
  fi
  if [[ -z "$RECOVERED" ]]; then
    RECOVERED="unknown"
  fi

  echo "redpanda_broker_bounce_exit_code=$CHAOS_CODE"
  echo "redpanda_broker_bounce_ok=$CHAOS_OK"
  echo "redpanda_broker_bounce_latest=$CHAOS_REPORT"
  echo "redpanda_broker_bounce_during_reachable=$DURING_REACHABLE"
  echo "redpanda_broker_bounce_recovered=$RECOVERED"

  BUDGET_OK="false"
  if "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"; then
    BUDGET_OK="true"
    echo "runbook_budget_ok=true"
  else
    BUDGET_OK="false"
    echo "runbook_budget_ok=false"
  fi

  SUMMARY_FILE="$OUT_DIR/redpanda-broker-bounce-summary.json"
  python3 - "$SUMMARY_FILE" "$CHAOS_REPORT" "$CHAOS_CODE" "$BUDGET_OK" "$DURING_REACHABLE" "$RECOVERED" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
chaos_report = pathlib.Path(sys.argv[2]).resolve()
chaos_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"
during_reachable = sys.argv[5]
recovered = sys.argv[6]

payload = {}
if chaos_report.exists():
    with open(chaos_report, "r", encoding="utf-8") as f:
        payload = json.load(f)

chaos_ok = bool(payload.get("ok", False)) if payload else False
connectivity = payload.get("connectivity", {}) if payload else {}
during_stop_reachable = connectivity.get("during_stop_broker_reachable")
after_restart_reachable = connectivity.get("after_restart_broker_reachable")
post_restart_consume_ok = connectivity.get("post_restart_consume_ok")

recommendation = "NO_ACTION"
if chaos_exit_code != 0 or not chaos_ok:
    recommendation = "INVESTIGATE_REDPANDA_BROKER_RECOVERY"
elif during_stop_reachable is True or during_reachable.lower() == "true":
    recommendation = "VERIFY_BROKER_STOP_ISOLATION"
elif after_restart_reachable is False or recovered.lower() == "false":
    recommendation = "VERIFY_BROKER_RESTART_RECOVERY"
elif post_restart_consume_ok is False:
    recommendation = "VERIFY_POST_RESTART_PRODUCE_CONSUME"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "redpanda_broker_bounce_report": str(chaos_report),
    "redpanda_broker_bounce_exit_code": chaos_exit_code,
    "redpanda_broker_bounce_ok": chaos_ok,
    "during_stop_broker_reachable": during_stop_reachable,
    "after_restart_broker_reachable": after_restart_reachable,
    "post_restart_consume_ok": post_restart_consume_ok,
    "budget_ok": budget_ok,
    "recommended_action": recommendation,
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  RECOMMENDED_ACTION="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("recommended_action", "UNKNOWN"))
PY
  )"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  RUNBOOK_OK=true
  if [[ "$CHAOS_CODE" -ne 0 && "$RUNBOOK_ALLOW_REDPANDA_BOUNCE_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$BUDGET_OK" != "true" && "$RUNBOOK_ALLOW_BUDGET_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi

  echo "redpanda_broker_bounce_recommended_action=$RECOMMENDED_ACTION"
  echo "runbook_redpanda_broker_bounce_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
