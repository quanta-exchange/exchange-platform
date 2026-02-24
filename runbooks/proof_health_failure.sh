#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/proof-health-${TS_ID}}"
LOG_FILE="$OUT_DIR/proof-health.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/proof-health-latest.json"

RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=proof_health_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  python3 - "$LATEST_SUMMARY_FILE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

path = pathlib.Path(sys.argv[1]).resolve()
payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "proof_health_ok": True,
    "tracked_count": 0,
    "present_count": 0,
    "missing_count": 0,
    "failing_count": 0,
    "missing_artifacts": [],
    "failing_artifacts": [],
    "recommended_action": "NO_ACTION",
}
path.parent.mkdir(parents=True, exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  set +e
  PROOF_OUTPUT="$("$ROOT_DIR/scripts/proof_health_metrics.sh" 2>&1)"
  PROOF_CODE=$?
  set -e
  echo "$PROOF_OUTPUT"

  PROOF_REPORT="$(extract_value "proof_health_metrics_latest" "$PROOF_OUTPUT")"
  if [[ -z "$PROOF_REPORT" ]]; then
    PROOF_REPORT="$(extract_value "proof_health_metrics_report" "$PROOF_OUTPUT")"
  fi
  PROOF_METRICS_OK="$(extract_value "proof_health_metrics_ok" "$PROOF_OUTPUT")"
  if [[ -z "$PROOF_METRICS_OK" ]]; then
    if [[ "$PROOF_CODE" -eq 0 ]]; then
      PROOF_METRICS_OK="true"
    else
      PROOF_METRICS_OK="false"
    fi
  fi

  BUDGET_OK="false"
  set +e
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR" >"$OUT_DIR/safety-budget.log" 2>&1
  BUDGET_CODE=$?
  set -e
  if [[ "$BUDGET_CODE" -eq 0 ]]; then
    BUDGET_OK="true"
  fi

  SUMMARY_FILE="$OUT_DIR/proof-health-summary.json"
  python3 - "$SUMMARY_FILE" "$PROOF_REPORT" "$PROOF_CODE" "$PROOF_METRICS_OK" "$BUDGET_OK" "$RUNBOOK_ALLOW_PROOF_FAIL" "$RUNBOOK_ALLOW_BUDGET_FAIL" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
proof_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
proof_exit_code = int(sys.argv[3])
proof_metrics_ok = sys.argv[4].lower() == "true"
budget_ok = sys.argv[5].lower() == "true"
allow_proof_fail = sys.argv[6].lower() == "true"
allow_budget_fail = sys.argv[7].lower() == "true"

proof_payload = {}
if proof_report and proof_report.exists():
    with open(proof_report, "r", encoding="utf-8") as f:
        proof_payload = json.load(f)

tracked = proof_payload.get("tracked", {}) if isinstance(proof_payload, dict) else {}
missing_artifacts = []
failing_artifacts = []
for name, artifact in tracked.items():
    if not isinstance(artifact, dict):
        continue
    if not bool(artifact.get("present", False)):
        missing_artifacts.append(name)
        continue
    if not bool(artifact.get("ok", False)):
        failing_artifacts.append(name)

tracked_count = int(proof_payload.get("tracked_count", len(tracked)) or 0)
present_count = int(proof_payload.get("present_count", tracked_count - len(missing_artifacts)) or 0)
failing_count = int(proof_payload.get("failing_count", len(failing_artifacts)) or 0)
missing_count = len(missing_artifacts)
proof_health_ok = missing_count == 0 and failing_count == 0

recommendation = "NO_ACTION"
if proof_exit_code != 0:
    recommendation = "INVESTIGATE_PROOF_HEALTH_EXPORTER"
elif missing_count > 0:
    recommendation = "RESTORE_MISSING_PROOF_ARTIFACTS"
elif failing_count > 0:
    recommendation = "INVESTIGATE_FAILING_PROOFS"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

runbook_ok = (
    (proof_exit_code == 0 or allow_proof_fail)
    and (proof_health_ok or allow_proof_fail)
    and (budget_ok or allow_budget_fail)
)

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": runbook_ok,
    "allow_proof_fail": allow_proof_fail,
    "allow_budget_fail": allow_budget_fail,
    "proof_report": str(proof_report) if proof_report else None,
    "proof_exit_code": proof_exit_code,
    "proof_metrics_ok": proof_metrics_ok,
    "proof_health_ok": proof_health_ok,
    "tracked_count": tracked_count,
    "present_count": present_count,
    "missing_count": missing_count,
    "failing_count": failing_count,
    "missing_artifacts": missing_artifacts,
    "failing_artifacts": failing_artifacts,
    "budget_ok": budget_ok,
    "recommended_action": recommendation,
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")
PY
  cp "$SUMMARY_FILE" "$LATEST_SUMMARY_FILE"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true

  RECOMMENDED_ACTION="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("recommended_action", "UNKNOWN"))
PY
  )"
  SUMMARY_PROOF_HEALTH_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("proof_health_ok") else "false")
PY
  )"
  SUMMARY_TRACKED_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("tracked_count", 0)))
PY
  )"
  SUMMARY_PRESENT_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("present_count", 0)))
PY
  )"
  SUMMARY_MISSING_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("missing_count", 0)))
PY
  )"
  SUMMARY_FAILING_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failing_count", 0)))
PY
  )"
  SUMMARY_MISSING_ARTIFACTS="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
values = payload.get("missing_artifacts", []) or []
print(",".join(str(v) for v in values))
PY
  )"
  SUMMARY_FAILING_ARTIFACTS="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
values = payload.get("failing_artifacts", []) or []
print(",".join(str(v) for v in values))
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

  echo "proof_health_metrics_exit_code=$PROOF_CODE"
  echo "proof_health_metrics_ok=$PROOF_METRICS_OK"
  echo "proof_health_runbook_proof_ok=$SUMMARY_PROOF_HEALTH_OK"
  echo "proof_health_runbook_tracked_count=$SUMMARY_TRACKED_COUNT"
  echo "proof_health_runbook_present_count=$SUMMARY_PRESENT_COUNT"
  echo "proof_health_runbook_missing_count=$SUMMARY_MISSING_COUNT"
  echo "proof_health_runbook_failing_count=$SUMMARY_FAILING_COUNT"
  echo "proof_health_runbook_missing_artifacts=$SUMMARY_MISSING_ARTIFACTS"
  echo "proof_health_runbook_failing_artifacts=$SUMMARY_FAILING_ARTIFACTS"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "proof_health_runbook_recommended_action=$RECOMMENDED_ACTION"
  echo "proof_health_summary_file=$SUMMARY_FILE"
  echo "proof_health_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_proof_health_ok=$SUMMARY_RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$SUMMARY_RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
