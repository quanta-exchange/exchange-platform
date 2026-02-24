#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/network-partition-${TS_ID}}"
LOG_FILE="$OUT_DIR/network-partition.log"
CHAOS_OUT_DIR="$OUT_DIR/chaos"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/network-partition-latest.json"

RUNBOOK_ALLOW_NETWORK_PARTITION_FAIL="${RUNBOOK_ALLOW_NETWORK_PARTITION_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=network_partition"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  CHAOS_OUTPUT="$(
    OUT_DIR="$CHAOS_OUT_DIR" "$ROOT_DIR/scripts/chaos/network_partition.sh" 2>&1
  )"
  CHAOS_CODE=$?
  set -e
  echo "$CHAOS_OUTPUT"

  CHAOS_OK="$(extract_value "chaos_network_partition_ok" "$CHAOS_OUTPUT")"
  CHAOS_REPORT="$(extract_value "chaos_network_partition_latest" "$CHAOS_OUTPUT")"
  DURING_REACHABLE="$(extract_value "chaos_network_partition_during_reachable" "$CHAOS_OUTPUT")"
  APPLIED_METHOD="$(extract_value "chaos_network_partition_method" "$CHAOS_OUTPUT")"

  if [[ -z "$CHAOS_REPORT" ]]; then
    CHAOS_REPORT="$CHAOS_OUT_DIR/network-partition-latest.json"
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
  if [[ -z "$APPLIED_METHOD" ]]; then
    APPLIED_METHOD="unknown"
  fi

  echo "chaos_network_partition_exit_code=$CHAOS_CODE"
  echo "chaos_network_partition_ok=$CHAOS_OK"
  echo "chaos_network_partition_latest=$CHAOS_REPORT"
  echo "chaos_network_partition_method=$APPLIED_METHOD"
  echo "chaos_network_partition_during_reachable=$DURING_REACHABLE"

  BUDGET_OK="false"
  if "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR"; then
    BUDGET_OK="true"
    echo "runbook_budget_ok=true"
  else
    BUDGET_OK="false"
    echo "runbook_budget_ok=false"
  fi

  SUMMARY_FILE="$OUT_DIR/network-partition-summary.json"
  python3 - "$SUMMARY_FILE" "$CHAOS_REPORT" "$CHAOS_CODE" "$BUDGET_OK" "$DURING_REACHABLE" "$APPLIED_METHOD" "$RUNBOOK_ALLOW_NETWORK_PARTITION_FAIL" "$RUNBOOK_ALLOW_BUDGET_FAIL" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
chaos_report = pathlib.Path(sys.argv[2]).resolve()
chaos_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"
during_reachable = sys.argv[5]
applied_method = sys.argv[6]
allow_network_partition_fail = sys.argv[7].lower() == "true"
allow_budget_fail = sys.argv[8].lower() == "true"

payload = {}
if chaos_report.exists():
    with open(chaos_report, "r", encoding="utf-8") as f:
        payload = json.load(f)

chaos_ok = bool(payload.get("ok", False)) if payload else False
connectivity = payload.get("connectivity", {}) if payload else {}
during_partition_reachable = connectivity.get("during_partition_broker_reachable")

recommendation = "NO_ACTION"
if chaos_exit_code != 0 or not chaos_ok:
    recommendation = "INVESTIGATE_REDPANDA_CONNECTIVITY_PATH"
elif during_partition_reachable is True or during_reachable.lower() == "true":
    recommendation = "VERIFY_ISOLATION_METHOD_AND_HOST_NETWORKING"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

runbook_ok = (
    ((chaos_exit_code == 0) and chaos_ok) or allow_network_partition_fail
) and (budget_ok or allow_budget_fail)

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": runbook_ok,
    "allow_network_partition_fail": allow_network_partition_fail,
    "allow_budget_fail": allow_budget_fail,
    "network_partition_report": str(chaos_report),
    "network_partition_exit_code": chaos_exit_code,
    "network_partition_ok": chaos_ok,
    "during_partition_broker_reachable": during_partition_reachable,
    "applied_isolation_method": applied_method,
    "budget_ok": budget_ok,
    "recommended_action": recommendation,
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  cp "$SUMMARY_FILE" "$LATEST_SUMMARY_FILE"

  RECOMMENDED_ACTION="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("recommended_action", "UNKNOWN"))
PY
  )"
  SUMMARY_RUNBOOK_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("runbook_ok") else "false")
PY
  )"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  echo "network_partition_recommended_action=$RECOMMENDED_ACTION"
  echo "network_partition_summary_file=$SUMMARY_FILE"
  echo "network_partition_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_network_partition_ok=$SUMMARY_RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$SUMMARY_RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
