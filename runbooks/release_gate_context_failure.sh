#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/release-gate-context-${TS_ID}}"
LOG_FILE="$OUT_DIR/release-gate-context.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/release-gate-context-latest.json"

RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"
RUNBOOK_REQUIRE_RUNBOOK_CONTEXT="${RUNBOOK_REQUIRE_RUNBOOK_CONTEXT:-true}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=release_gate_context_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  BASE_RELEASE_GATE_REPORT="$OUT_DIR/release-gate-baseline.json"
  python3 - "$BASE_RELEASE_GATE_REPORT" "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
require_runbook_context = sys.argv[2].lower() == "true"

required_fields = [
    "policy_signature_runbook_ok",
    "policy_signature_runbook_budget_ok",
    "policy_tamper_runbook_ok",
    "policy_tamper_runbook_budget_ok",
    "network_partition_runbook_ok",
    "network_partition_runbook_budget_ok",
    "redpanda_bounce_runbook_ok",
    "redpanda_bounce_runbook_budget_ok",
    "adversarial_runbook_ok",
    "adversarial_runbook_budget_ok",
    "exactly_once_runbook_ok",
    "exactly_once_runbook_budget_ok",
    "mapping_integrity_runbook_ok",
    "mapping_integrity_runbook_budget_ok",
    "mapping_coverage_runbook_ok",
    "mapping_coverage_runbook_budget_ok",
    "idempotency_latch_runbook_ok",
    "idempotency_latch_runbook_budget_ok",
    "idempotency_key_format_runbook_ok",
    "idempotency_key_format_runbook_budget_ok",
    "proof_health_runbook_ok",
    "proof_health_runbook_budget_ok",
]

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": True,
    "require_runbook_context": require_runbook_context,
    "runbook_context_required_fields": required_fields,
    "runbook_context_missing": [],
    "runbook_context_backfill_ok": True,
}
for field in required_fields:
    payload[field] = True

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  BASELINE_FALLBACK_CMD=(
    "$ROOT_DIR/scripts/release_gate_fallback_smoke.sh"
    --out-dir
    "$OUT_DIR/fallback-baseline"
    --skip-release-gate
    --report-file
    "$BASE_RELEASE_GATE_REPORT"
  )
  if [[ "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" == "true" ]]; then
    BASELINE_FALLBACK_CMD+=(--require-runbook-context)
  fi

  set +e
  BASELINE_FALLBACK_OUTPUT="$("${BASELINE_FALLBACK_CMD[@]}" 2>&1)"
  BASELINE_FALLBACK_CODE=$?
  set -e
  echo "$BASELINE_FALLBACK_OUTPUT"

  BASELINE_FALLBACK_REPORT="$(extract_value "release_gate_fallback_smoke_latest" "$BASELINE_FALLBACK_OUTPUT")"
  if [[ -z "$BASELINE_FALLBACK_REPORT" ]]; then
    BASELINE_FALLBACK_REPORT="$(extract_value "release_gate_fallback_smoke_report" "$BASELINE_FALLBACK_OUTPUT")"
  fi
  BASELINE_FALLBACK_OK="$(extract_value "release_gate_fallback_smoke_ok" "$BASELINE_FALLBACK_OUTPUT")"
  if [[ -z "$BASELINE_FALLBACK_OK" ]]; then
    if [[ "$BASELINE_FALLBACK_CODE" -eq 0 ]]; then
      BASELINE_FALLBACK_OK=true
    else
      BASELINE_FALLBACK_OK=false
    fi
  fi

  BASELINE_PROOF_CMD=(
    "$ROOT_DIR/scripts/prove_release_gate_context.sh"
    --out-dir
    "$OUT_DIR/proof-baseline"
    --release-gate-report
    "$BASE_RELEASE_GATE_REPORT"
  )
  if [[ -n "$BASELINE_FALLBACK_REPORT" ]]; then
    BASELINE_PROOF_CMD+=(--fallback-smoke-report "$BASELINE_FALLBACK_REPORT")
  fi
  if [[ "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" == "true" ]]; then
    BASELINE_PROOF_CMD+=(--expect-require-runbook-context)
  else
    BASELINE_PROOF_CMD+=(--allow-require-runbook-context-false)
  fi

  set +e
  BASELINE_PROOF_OUTPUT="$("${BASELINE_PROOF_CMD[@]}" 2>&1)"
  BASELINE_PROOF_CODE=$?
  set -e
  echo "$BASELINE_PROOF_OUTPUT"

  BASELINE_PROOF_REPORT="$(extract_value "prove_release_gate_context_latest" "$BASELINE_PROOF_OUTPUT")"
  if [[ -z "$BASELINE_PROOF_REPORT" ]]; then
    BASELINE_PROOF_REPORT="$(extract_value "prove_release_gate_context_report" "$BASELINE_PROOF_OUTPUT")"
  fi
  BASELINE_PROOF_OK="$(extract_value "prove_release_gate_context_ok" "$BASELINE_PROOF_OUTPUT")"
  if [[ -z "$BASELINE_PROOF_OK" ]]; then
    if [[ "$BASELINE_PROOF_CODE" -eq 0 ]]; then
      BASELINE_PROOF_OK=true
    else
      BASELINE_PROOF_OK=false
    fi
  fi

  TAMPERED_RELEASE_GATE_REPORT="$OUT_DIR/release-gate-tampered.json"
  python3 - "$BASE_RELEASE_GATE_REPORT" "$TAMPERED_RELEASE_GATE_REPORT" "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

baseline_file = pathlib.Path(sys.argv[1]).resolve()
out_file = pathlib.Path(sys.argv[2]).resolve()
require_runbook_context = sys.argv[3].lower() == "true"

with open(baseline_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

required_fields = list(payload.get("runbook_context_required_fields", []) or [])
missing_field = required_fields[-1] if required_fields else "proof_health_runbook_budget_ok"
payload[missing_field] = None
payload["ok"] = False
payload["require_runbook_context"] = require_runbook_context
payload["runbook_context_backfill_ok"] = False
payload["runbook_context_missing"] = [missing_field]
payload["generated_at_utc"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

out_file.parent.mkdir(parents=True, exist_ok=True)
with open(out_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  TAMPERED_FALLBACK_CMD=(
    "$ROOT_DIR/scripts/release_gate_fallback_smoke.sh"
    --out-dir
    "$OUT_DIR/fallback-tampered"
    --skip-release-gate
    --report-file
    "$TAMPERED_RELEASE_GATE_REPORT"
  )
  if [[ "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" == "true" ]]; then
    TAMPERED_FALLBACK_CMD+=(--require-runbook-context)
  fi

  set +e
  TAMPERED_FALLBACK_OUTPUT="$("${TAMPERED_FALLBACK_CMD[@]}" 2>&1)"
  TAMPERED_FALLBACK_CODE=$?
  set -e
  echo "$TAMPERED_FALLBACK_OUTPUT"

  TAMPERED_FALLBACK_REPORT="$(extract_value "release_gate_fallback_smoke_latest" "$TAMPERED_FALLBACK_OUTPUT")"
  if [[ -z "$TAMPERED_FALLBACK_REPORT" ]]; then
    TAMPERED_FALLBACK_REPORT="$(extract_value "release_gate_fallback_smoke_report" "$TAMPERED_FALLBACK_OUTPUT")"
  fi
  TAMPERED_FALLBACK_OK="$(extract_value "release_gate_fallback_smoke_ok" "$TAMPERED_FALLBACK_OUTPUT")"
  if [[ -z "$TAMPERED_FALLBACK_OK" ]]; then
    if [[ "$TAMPERED_FALLBACK_CODE" -eq 0 ]]; then
      TAMPERED_FALLBACK_OK=true
    else
      TAMPERED_FALLBACK_OK=false
    fi
  fi

  TAMPERED_PROOF_CMD=(
    "$ROOT_DIR/scripts/prove_release_gate_context.sh"
    --out-dir
    "$OUT_DIR/proof-tampered"
    --release-gate-report
    "$TAMPERED_RELEASE_GATE_REPORT"
  )
  if [[ -n "$TAMPERED_FALLBACK_REPORT" ]]; then
    TAMPERED_PROOF_CMD+=(--fallback-smoke-report "$TAMPERED_FALLBACK_REPORT")
  fi
  if [[ "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" == "true" ]]; then
    TAMPERED_PROOF_CMD+=(--expect-require-runbook-context)
  else
    TAMPERED_PROOF_CMD+=(--allow-require-runbook-context-false)
  fi

  set +e
  TAMPERED_PROOF_OUTPUT="$("${TAMPERED_PROOF_CMD[@]}" 2>&1)"
  TAMPERED_PROOF_CODE=$?
  set -e
  echo "$TAMPERED_PROOF_OUTPUT"

  TAMPERED_PROOF_REPORT="$(extract_value "prove_release_gate_context_latest" "$TAMPERED_PROOF_OUTPUT")"
  if [[ -z "$TAMPERED_PROOF_REPORT" ]]; then
    TAMPERED_PROOF_REPORT="$(extract_value "prove_release_gate_context_report" "$TAMPERED_PROOF_OUTPUT")"
  fi
  TAMPERED_PROOF_OK="$(extract_value "prove_release_gate_context_ok" "$TAMPERED_PROOF_OUTPUT")"
  if [[ -z "$TAMPERED_PROOF_OK" ]]; then
    if [[ "$TAMPERED_PROOF_CODE" -eq 0 ]]; then
      TAMPERED_PROOF_OK=true
    else
      TAMPERED_PROOF_OK=false
    fi
  fi

  BUDGET_OK=false
  set +e
  "$ROOT_DIR/scripts/safety_budget_check.sh" --out-dir "$OUT_DIR" >"$OUT_DIR/safety-budget.log" 2>&1
  BUDGET_CODE=$?
  set -e
  if [[ "$BUDGET_CODE" -eq 0 ]]; then
    BUDGET_OK=true
  fi

  SUMMARY_FILE="$OUT_DIR/release-gate-context-summary.json"
  python3 - "$SUMMARY_FILE" \
    "$BASELINE_PROOF_REPORT" "$BASELINE_PROOF_CODE" "$BASELINE_PROOF_OK" \
    "$BASELINE_FALLBACK_REPORT" "$BASELINE_FALLBACK_CODE" "$BASELINE_FALLBACK_OK" \
    "$TAMPERED_PROOF_REPORT" "$TAMPERED_PROOF_CODE" "$TAMPERED_PROOF_OK" \
    "$TAMPERED_FALLBACK_REPORT" "$TAMPERED_FALLBACK_CODE" "$TAMPERED_FALLBACK_OK" \
    "$BUDGET_OK" "$RUNBOOK_ALLOW_PROOF_FAIL" "$RUNBOOK_ALLOW_BUDGET_FAIL" "$RUNBOOK_REQUIRE_RUNBOOK_CONTEXT" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
baseline_proof_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
baseline_proof_exit_code = int(sys.argv[3])
baseline_proof_ok = sys.argv[4].lower() == "true"
baseline_fallback_report = pathlib.Path(sys.argv[5]).resolve() if sys.argv[5] else None
baseline_fallback_exit_code = int(sys.argv[6])
baseline_fallback_ok = sys.argv[7].lower() == "true"
tampered_proof_report = pathlib.Path(sys.argv[8]).resolve() if sys.argv[8] else None
tampered_proof_exit_code = int(sys.argv[9])
tampered_proof_ok = sys.argv[10].lower() == "true"
tampered_fallback_report = pathlib.Path(sys.argv[11]).resolve() if sys.argv[11] else None
tampered_fallback_exit_code = int(sys.argv[12])
tampered_fallback_ok = sys.argv[13].lower() == "true"
budget_ok = sys.argv[14].lower() == "true"
allow_proof_fail = sys.argv[15].lower() == "true"
allow_budget_fail = sys.argv[16].lower() == "true"
require_runbook_context = sys.argv[17].lower() == "true"


def read_payload(path):
    if path and path.exists():
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


baseline_proof_payload = read_payload(baseline_proof_report)
baseline_fallback_payload = read_payload(baseline_fallback_report)
tampered_proof_payload = read_payload(tampered_proof_report)
tampered_fallback_payload = read_payload(tampered_fallback_report)

baseline_failed_checks_count = len(baseline_proof_payload.get("failed_checks", []) or [])
baseline_missing_fields_count = len(
    baseline_fallback_payload.get("missing_fields", []) or []
)
tampered_failed_checks_count = len(tampered_proof_payload.get("failed_checks", []) or [])
tampered_missing_fields_count = len(
    tampered_fallback_payload.get("missing_fields", []) or []
)

baseline_expected_pass = (
    baseline_proof_exit_code == 0
    and baseline_proof_ok
    and baseline_fallback_exit_code == 0
    and baseline_fallback_ok
    and baseline_failed_checks_count == 0
    and baseline_missing_fields_count == 0
)

tampered_proof_expected_fail = (
    tampered_proof_exit_code != 0
    and (not tampered_proof_ok)
    and tampered_failed_checks_count > 0
)
tampered_fallback_expected_fail = (
    tampered_fallback_exit_code != 0
    and (not tampered_fallback_ok)
    and tampered_missing_fields_count > 0
)

proof_ok = (
    baseline_expected_pass
    and tampered_proof_expected_fail
    and tampered_fallback_expected_fail
)
runbook_ok = (proof_ok or allow_proof_fail) and (budget_ok or allow_budget_fail)

recommended_action = "NO_ACTION"
if not baseline_expected_pass:
    recommended_action = "INVESTIGATE_RELEASE_GATE_CONTEXT_BASELINE"
elif not tampered_proof_expected_fail:
    recommended_action = "INVESTIGATE_RELEASE_GATE_CONTEXT_PROOF_ENFORCEMENT"
elif not tampered_fallback_expected_fail:
    recommended_action = "INVESTIGATE_RELEASE_GATE_FALLBACK_SMOKE_ENFORCEMENT"
elif not budget_ok:
    recommended_action = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": runbook_ok,
    "allow_proof_fail": allow_proof_fail,
    "allow_budget_fail": allow_budget_fail,
    "require_runbook_context": require_runbook_context,
    "proof_ok": proof_ok,
    "baseline_expected_pass": baseline_expected_pass,
    "baseline_proof_report": str(baseline_proof_report) if baseline_proof_report else None,
    "baseline_proof_exit_code": baseline_proof_exit_code,
    "baseline_proof_ok": baseline_proof_ok,
    "baseline_failed_checks_count": baseline_failed_checks_count,
    "baseline_fallback_report": str(baseline_fallback_report) if baseline_fallback_report else None,
    "baseline_fallback_exit_code": baseline_fallback_exit_code,
    "baseline_fallback_ok": baseline_fallback_ok,
    "baseline_missing_fields_count": baseline_missing_fields_count,
    "failure_probe_expected_fail": tampered_proof_expected_fail,
    "failure_probe_report": str(tampered_proof_report) if tampered_proof_report else None,
    "failure_probe_exit_code": tampered_proof_exit_code,
    "failure_probe_ok": tampered_proof_ok,
    "failure_probe_failed_checks_count": tampered_failed_checks_count,
    "failure_fallback_expected_fail": tampered_fallback_expected_fail,
    "failure_fallback_report": str(tampered_fallback_report) if tampered_fallback_report else None,
    "failure_fallback_exit_code": tampered_fallback_exit_code,
    "failure_fallback_ok": tampered_fallback_ok,
    "failure_fallback_missing_fields_count": tampered_missing_fields_count,
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
  SUMMARY_BASELINE_PROOF_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("baseline_proof_ok") else "false")
PY
  )"
  SUMMARY_BASELINE_FALLBACK_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("baseline_fallback_ok") else "false")
PY
  )"
  SUMMARY_FAILURE_PROBE_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failure_probe_exit_code", 0)))
PY
  )"
  SUMMARY_FAILURE_PROBE_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("failure_probe_ok") else "false")
PY
  )"
  SUMMARY_FAILURE_PROBE_FAILED_CHECKS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failure_probe_failed_checks_count", 0)))
PY
  )"
  SUMMARY_FAILURE_FALLBACK_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failure_fallback_exit_code", 0)))
PY
  )"
  SUMMARY_FAILURE_FALLBACK_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("failure_fallback_ok") else "false")
PY
  )"
  SUMMARY_FAILURE_FALLBACK_MISSING_FIELDS_COUNT="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failure_fallback_missing_fields_count", 0)))
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

  echo "release_gate_context_baseline_proof_exit_code=$BASELINE_PROOF_CODE"
  echo "release_gate_context_baseline_proof_ok=$SUMMARY_BASELINE_PROOF_OK"
  echo "release_gate_context_baseline_fallback_exit_code=$BASELINE_FALLBACK_CODE"
  echo "release_gate_context_baseline_fallback_ok=$SUMMARY_BASELINE_FALLBACK_OK"
  echo "release_gate_context_failure_probe_exit_code=$SUMMARY_FAILURE_PROBE_EXIT_CODE"
  echo "release_gate_context_failure_probe_ok=$SUMMARY_FAILURE_PROBE_OK"
  echo "release_gate_context_failure_probe_failed_checks_count=$SUMMARY_FAILURE_PROBE_FAILED_CHECKS_COUNT"
  echo "release_gate_context_failure_fallback_exit_code=$SUMMARY_FAILURE_FALLBACK_EXIT_CODE"
  echo "release_gate_context_failure_fallback_ok=$SUMMARY_FAILURE_FALLBACK_OK"
  echo "release_gate_context_failure_fallback_missing_fields_count=$SUMMARY_FAILURE_FALLBACK_MISSING_FIELDS_COUNT"
  echo "release_gate_context_proof_ok=$SUMMARY_PROOF_OK"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "release_gate_context_recommended_action=$RECOMMENDED_ACTION"
  echo "release_gate_context_summary_file=$SUMMARY_FILE"
  echo "release_gate_context_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_release_gate_context_ok=$SUMMARY_RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$SUMMARY_RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
