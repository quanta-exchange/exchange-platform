#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/mapping-coverage-${TS_ID}}"
LOG_FILE="$OUT_DIR/mapping-coverage.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/mapping-coverage-latest.json"

RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=mapping_coverage_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  BASE_PROOF_OUT_DIR="$OUT_DIR/baseline-proof"
  set +e
  BASE_PROOF_OUTPUT="$("$ROOT_DIR/scripts/prove_mapping_coverage.sh" --out-dir "$BASE_PROOF_OUT_DIR" 2>&1)"
  BASE_PROOF_CODE=$?
  set -e
  echo "$BASE_PROOF_OUTPUT"

  BASE_PROOF_REPORT="$(extract_value "prove_mapping_coverage_latest" "$BASE_PROOF_OUTPUT")"
  if [[ -z "$BASE_PROOF_REPORT" ]]; then
    BASE_PROOF_REPORT="$(extract_value "prove_mapping_coverage_report" "$BASE_PROOF_OUTPUT")"
  fi

  AUG_CONTROLS_FILE="$OUT_DIR/controls-augmented.json"
  python3 - "$ROOT_DIR/controls/controls.yaml" "$AUG_CONTROLS_FILE" "$TS_ID" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).resolve()
dst = pathlib.Path(sys.argv[2]).resolve()
suffix = sys.argv[3]

with open(src, "r", encoding="utf-8") as f:
    payload = json.load(f)

controls = payload.get("controls", [])
if not isinstance(controls, list):
    raise SystemExit("controls catalog format invalid")

controls.append(
    {
        "id": f"CTRL-RUNBOOK-MAPPING-COVERAGE-{suffix}",
        "title": "Runbook synthetic unmapped control for full/partial coverage mode probe",
        "enforced": False,
        "required_evidence": [],
    }
)

dst.parent.mkdir(parents=True, exist_ok=True)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  STRICT_PROBE_OUT_DIR="$OUT_DIR/strict-probe"
  set +e
  STRICT_PROBE_OUTPUT="$("$ROOT_DIR/scripts/prove_mapping_coverage.sh" --controls-file "$AUG_CONTROLS_FILE" --mapping-file "$ROOT_DIR/compliance/mapping.yaml" --out-dir "$STRICT_PROBE_OUT_DIR" --require-full-coverage 2>&1)"
  STRICT_PROBE_CODE=$?
  set -e
  echo "$STRICT_PROBE_OUTPUT"

  STRICT_PROBE_REPORT="$(extract_value "prove_mapping_coverage_latest" "$STRICT_PROBE_OUTPUT")"
  if [[ -z "$STRICT_PROBE_REPORT" ]]; then
    STRICT_PROBE_REPORT="$(extract_value "prove_mapping_coverage_report" "$STRICT_PROBE_OUTPUT")"
  fi

  PARTIAL_PROBE_OUT_DIR="$OUT_DIR/partial-probe"
  set +e
  PARTIAL_PROBE_OUTPUT="$("$ROOT_DIR/scripts/prove_mapping_coverage.sh" --controls-file "$AUG_CONTROLS_FILE" --mapping-file "$ROOT_DIR/compliance/mapping.yaml" --out-dir "$PARTIAL_PROBE_OUT_DIR" --allow-partial-coverage 2>&1)"
  PARTIAL_PROBE_CODE=$?
  set -e
  echo "$PARTIAL_PROBE_OUTPUT"

  PARTIAL_PROBE_REPORT="$(extract_value "prove_mapping_coverage_latest" "$PARTIAL_PROBE_OUTPUT")"
  if [[ -z "$PARTIAL_PROBE_REPORT" ]]; then
    PARTIAL_PROBE_REPORT="$(extract_value "prove_mapping_coverage_report" "$PARTIAL_PROBE_OUTPUT")"
  fi

  BUDGET_OK="false"
  set +e
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR" >"$OUT_DIR/safety-budget.log" 2>&1
  BUDGET_CODE=$?
  set -e
  if [[ "$BUDGET_CODE" -eq 0 ]]; then
    BUDGET_OK="true"
  fi

  SUMMARY_FILE="$OUT_DIR/mapping-coverage-summary.json"
  python3 - "$SUMMARY_FILE" "$BASE_PROOF_REPORT" "$BASE_PROOF_CODE" "$STRICT_PROBE_REPORT" "$STRICT_PROBE_CODE" "$PARTIAL_PROBE_REPORT" "$PARTIAL_PROBE_CODE" "$BUDGET_OK" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
baseline_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
baseline_exit_code = int(sys.argv[3])
strict_report = pathlib.Path(sys.argv[4]).resolve() if sys.argv[4] else None
strict_exit_code = int(sys.argv[5])
partial_report = pathlib.Path(sys.argv[6]).resolve() if sys.argv[6] else None
partial_exit_code = int(sys.argv[7])
budget_ok = sys.argv[8].lower() == "true"


def read_payload(path: pathlib.Path | None):
    if path and path.exists():
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


baseline_payload = read_payload(baseline_report)
strict_payload = read_payload(strict_report)
partial_payload = read_payload(partial_report)

baseline_ok = bool(baseline_payload.get("ok", False))
baseline_coverage_ratio = float(baseline_payload.get("mapping_coverage_ratio", 0.0) or 0.0)
baseline_unmapped_controls_count = int(
    baseline_payload.get("unmapped_controls_count", 0) or 0
)

strict_ok = bool(strict_payload.get("ok", False))
strict_missing_controls_count = int(strict_payload.get("missing_controls_count", 0) or 0)
strict_unmapped_controls_count = int(strict_payload.get("unmapped_controls_count", 0) or 0)

partial_ok = bool(partial_payload.get("ok", False))
partial_unmapped_controls_count = int(partial_payload.get("unmapped_controls_count", 0) or 0)
partial_unmapped_enforced_controls_count = int(
    partial_payload.get("unmapped_enforced_controls_count", 0) or 0
)

strict_probe_expected_fail = strict_exit_code != 0 and (not strict_ok)
partial_probe_expected_pass = (
    partial_exit_code == 0
    and partial_ok
    and partial_unmapped_enforced_controls_count == 0
)
proof_ok = baseline_ok and strict_probe_expected_fail and partial_probe_expected_pass

recommended_action = "NO_ACTION"
if baseline_exit_code != 0 or not baseline_ok:
    recommended_action = "INVESTIGATE_BASELINE_MAPPING_COVERAGE"
elif strict_exit_code == 0 or strict_ok:
    recommended_action = "INVESTIGATE_FULL_COVERAGE_ENFORCEMENT"
elif partial_exit_code != 0 or not partial_ok:
    recommended_action = "INVESTIGATE_PARTIAL_COVERAGE_MODE"
elif partial_unmapped_enforced_controls_count > 0:
    recommended_action = "INVESTIGATE_ENFORCED_MAPPING_GUARD"
elif not budget_ok:
    recommended_action = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "proof_ok": proof_ok,
    "baseline_report": str(baseline_report) if baseline_report else None,
    "baseline_exit_code": baseline_exit_code,
    "baseline_ok": baseline_ok,
    "baseline_coverage_ratio": baseline_coverage_ratio,
    "baseline_unmapped_controls_count": baseline_unmapped_controls_count,
    "strict_probe_report": str(strict_report) if strict_report else None,
    "strict_probe_exit_code": strict_exit_code,
    "strict_probe_ok": strict_ok,
    "strict_missing_controls_count": strict_missing_controls_count,
    "strict_unmapped_controls_count": strict_unmapped_controls_count,
    "strict_probe_expected_fail": strict_probe_expected_fail,
    "partial_probe_report": str(partial_report) if partial_report else None,
    "partial_probe_exit_code": partial_exit_code,
    "partial_probe_ok": partial_ok,
    "partial_unmapped_controls_count": partial_unmapped_controls_count,
    "partial_unmapped_enforced_controls_count": partial_unmapped_enforced_controls_count,
    "partial_probe_expected_pass": partial_probe_expected_pass,
    "budget_ok": budget_ok,
    "recommended_action": recommended_action,
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
  SUMMARY_PROOF_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("proof_ok") else "false")
PY
  )"
  SUMMARY_BASELINE_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("baseline_ok") else "false")
PY
  )"
  SUMMARY_STRICT_PROBE_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("strict_probe_exit_code", 0)))
PY
  )"
  SUMMARY_STRICT_UNMAPPED_CONTROLS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("strict_unmapped_controls_count", 0)))
PY
  )"
  SUMMARY_PARTIAL_PROBE_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("partial_probe_exit_code", 0)))
PY
  )"
  SUMMARY_PARTIAL_UNMAPPED_CONTROLS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("partial_unmapped_controls_count", 0)))
PY
  )"
  SUMMARY_PARTIAL_UNMAPPED_ENFORCED_CONTROLS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("partial_unmapped_enforced_controls_count", 0)))
PY
  )"

  RUNBOOK_OK=true
  if [[ "$SUMMARY_PROOF_OK" != "true" && "$RUNBOOK_ALLOW_PROOF_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$BUDGET_OK" != "true" && "$RUNBOOK_ALLOW_BUDGET_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi

  echo "mapping_coverage_baseline_proof_exit_code=$BASE_PROOF_CODE"
  echo "mapping_coverage_baseline_ok=$SUMMARY_BASELINE_OK"
  echo "mapping_coverage_strict_probe_exit_code=$SUMMARY_STRICT_PROBE_EXIT_CODE"
  echo "mapping_coverage_strict_unmapped_controls_count=$SUMMARY_STRICT_UNMAPPED_CONTROLS_COUNT"
  echo "mapping_coverage_partial_probe_exit_code=$SUMMARY_PARTIAL_PROBE_EXIT_CODE"
  echo "mapping_coverage_partial_unmapped_controls_count=$SUMMARY_PARTIAL_UNMAPPED_CONTROLS_COUNT"
  echo "mapping_coverage_partial_unmapped_enforced_controls_count=$SUMMARY_PARTIAL_UNMAPPED_ENFORCED_CONTROLS_COUNT"
  echo "mapping_coverage_proof_ok=$SUMMARY_PROOF_OK"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "mapping_coverage_recommended_action=$RECOMMENDED_ACTION"
  echo "mapping_coverage_summary_file=$SUMMARY_FILE"
  echo "mapping_coverage_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_mapping_coverage_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
