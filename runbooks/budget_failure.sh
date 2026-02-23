#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/budget-failure-${TS_ID}}"
LOG_FILE="$OUT_DIR/budget-failure.log"

mkdir -p "$OUT_DIR"

{
  echo "runbook=budget_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR" >"$OUT_DIR/safety-budget.log" 2>&1
  BUDGET_CODE=$?
  set -e

  BUDGET_LATEST="$OUT_DIR/safety-budget-latest.json"
  SUMMARY_FILE="$OUT_DIR/budget-failure-summary.json"

  python3 - "$BUDGET_LATEST" "$SUMMARY_FILE" "$BUDGET_CODE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

budget_latest = pathlib.Path(sys.argv[1]).resolve()
summary_file = pathlib.Path(sys.argv[2]).resolve()
budget_code = int(sys.argv[3])

payload = {}
if budget_latest.exists():
    payload = json.loads(budget_latest.read_text(encoding="utf-8"))

violations = list(payload.get("violations", []) or []) if isinstance(payload, dict) else []
budget_ok = bool(payload.get("ok", False)) if isinstance(payload, dict) else False

recommendation = "NO_ACTION"
if not budget_ok:
    if any("load_thresholds_not_checked" in v for v in violations):
        recommendation = "RUN_LOAD_SMOKE_AND_RECHECK"
    elif any("stale_report" in v for v in violations):
        recommendation = "REFRESH_ARTIFACTS_AND_RECHECK"
    elif any("anomaly_detected" in v for v in violations):
        recommendation = "CHECK_ANOMALY_SIGNAL_AND_CONSIDER_CANCEL_ONLY"
    else:
        recommendation = "INVESTIGATE_BUDGET_VIOLATIONS"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "budget_exit_code": budget_code,
    "budget_ok": budget_ok,
    "violation_count": len(violations),
    "violations": violations,
    "recommended_action": recommendation,
    "budget_latest_report": str(budget_latest),
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  BUDGET_OK_VALUE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    summary = json.load(f)
print("true" if summary.get("budget_ok") else "false")
PY
  )"
  VIOLATION_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    summary = json.load(f)
print(int(summary.get("violation_count", 0)))
PY
  )"
  RECOMMENDED_ACTION="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    summary = json.load(f)
print(summary.get("recommended_action", "UNKNOWN"))
PY
  )"

  echo "budget_ok=$BUDGET_OK_VALUE"
  echo "budget_violation_count=$VIOLATION_COUNT"
  echo "budget_recommended_action=$RECOMMENDED_ACTION"
  echo "runbook_budget_failure_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
