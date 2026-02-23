#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/release-gate}"
RUN_CHECKS=false
RUN_EXTENDED_CHECKS=false
RUN_LOAD_PROFILES=false
RUN_STARTUP_GUARDRAILS=false
RUN_CHANGE_WORKFLOW=false
STRICT_CONTROLS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --run-checks)
      RUN_CHECKS=true
      shift
      ;;
    --run-extended-checks)
      RUN_EXTENDED_CHECKS=true
      shift
      ;;
    --run-load-profiles)
      RUN_LOAD_PROFILES=true
      shift
      ;;
    --run-startup-guardrails)
      RUN_STARTUP_GUARDRAILS=true
      shift
      ;;
    --run-change-workflow)
      RUN_CHANGE_WORKFLOW=true
      shift
      ;;
    --strict-controls)
      STRICT_CONTROLS=true
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/release-gate-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/release-gate-latest.json"

VERIFY_CMD=("$ROOT_DIR/scripts/verification_factory.sh")
if [[ "$RUN_CHECKS" == "true" ]]; then
  VERIFY_CMD+=("--run-checks")
fi
if [[ "$RUN_EXTENDED_CHECKS" == "true" ]]; then
  VERIFY_CMD+=("--run-extended-checks")
fi
if [[ "$RUN_LOAD_PROFILES" == "true" ]]; then
  VERIFY_CMD+=("--run-load-profiles")
fi
if [[ "$RUN_STARTUP_GUARDRAILS" == "true" ]]; then
  VERIFY_CMD+=("--run-startup-guardrails")
fi
if [[ "$RUN_CHANGE_WORKFLOW" == "true" ]]; then
  VERIFY_CMD+=("--run-change-workflow")
fi

set +e
VERIFY_OUTPUT="$("${VERIFY_CMD[@]}" 2>&1)"
VERIFY_EXIT_CODE=$?
set -e
echo "$VERIFY_OUTPUT"
VERIFY_SUMMARY="$(echo "$VERIFY_OUTPUT" | awk -F= '/^verification_summary=/{print $2}' | tail -n 1)"
VERIFY_OK="$(echo "$VERIFY_OUTPUT" | awk -F= '/^verification_ok=/{print $2}' | tail -n 1)"
if [[ -z "$VERIFY_OK" ]]; then
  if [[ "$VERIFY_EXIT_CODE" -eq 0 ]]; then
    VERIFY_OK=true
  else
    VERIFY_OK=false
  fi
fi

if [[ -z "$VERIFY_SUMMARY" || ! -f "$VERIFY_SUMMARY" ]]; then
  echo "verification summary missing" >&2
  exit 1
fi

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"

python3 - "$REPORT_FILE" "$VERIFY_SUMMARY" "$VERIFY_OK" "$VERIFY_EXIT_CODE" "$COMMIT" "$BRANCH" "$RUN_CHECKS" "$RUN_EXTENDED_CHECKS" "$RUN_LOAD_PROFILES" "$RUN_STARTUP_GUARDRAILS" "$RUN_CHANGE_WORKFLOW" "$STRICT_CONTROLS" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
verification_summary = pathlib.Path(sys.argv[2]).resolve()
verification_ok = sys.argv[3].lower() == "true"
verification_exit_code = int(sys.argv[4])
git_commit = sys.argv[5]
git_branch = sys.argv[6]
run_checks = sys.argv[7].lower() == "true"
run_extended_checks = sys.argv[8].lower() == "true"
run_load_profiles = sys.argv[9].lower() == "true"
run_startup_guardrails = sys.argv[10].lower() == "true"
run_change_workflow = sys.argv[11].lower() == "true"
strict_controls = sys.argv[12].lower() == "true"

with open(verification_summary, "r", encoding="utf-8") as f:
    summary = json.load(f)

controls_report_path = summary.get("artifacts", {}).get("controls_check_report")
controls_advisory_missing = None
if controls_report_path:
    candidate = pathlib.Path(controls_report_path)
    if not candidate.is_absolute():
        candidate = (verification_summary.parent / candidate).resolve()
    if candidate.exists():
        with open(candidate, "r", encoding="utf-8") as f:
            controls_payload = json.load(f)
        controls_advisory_missing = int(controls_payload.get("advisory_missing_count", 0))

controls_gate_ok = True
if strict_controls:
    controls_gate_ok = controls_advisory_missing == 0

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": verification_ok and bool(summary.get("ok", False)) and controls_gate_ok,
    "git_commit": git_commit,
    "git_branch": git_branch,
    "verification_exit_code": verification_exit_code,
    "run_checks": run_checks,
    "run_extended_checks": run_extended_checks,
    "run_load_profiles": run_load_profiles,
    "run_startup_guardrails": run_startup_guardrails,
    "run_change_workflow": run_change_workflow,
    "strict_controls": strict_controls,
    "controls_advisory_missing_count": controls_advisory_missing,
    "controls_gate_ok": controls_gate_ok,
    "verification_run_load_profiles": bool(summary.get("run_load_profiles", False)),
    "verification_run_startup_guardrails": bool(summary.get("run_startup_guardrails", False)),
    "verification_run_change_workflow": bool(summary.get("run_change_workflow", False)),
    "verification_summary": str(verification_summary),
    "verification_step_count": len(summary.get("steps", [])),
    "failed_steps": [s.get("name") for s in summary.get("steps", []) if s.get("status") != "pass"],
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

GATE_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "release_gate_report=${REPORT_FILE}"
echo "release_gate_latest=${LATEST_FILE}"
echo "release_gate_ok=${GATE_OK}"

if [[ "$GATE_OK" != "true" ]]; then
  exit 1
fi
