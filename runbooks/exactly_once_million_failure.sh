#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/exactly-once-million-${TS_ID}}"
LOG_FILE="$OUT_DIR/exactly-once-million.log"
LATEST_SUMMARY_FILE="$ROOT_DIR/build/runbooks/exactly-once-million-latest.json"

RUNBOOK_REPEATS="${RUNBOOK_REPEATS:-1000000}"
RUNBOOK_CONCURRENCY="${RUNBOOK_CONCURRENCY:-64}"
RUNBOOK_ALLOW_PROOF_FAIL="${RUNBOOK_ALLOW_PROOF_FAIL:-false}"
RUNBOOK_ALLOW_BUDGET_FAIL="${RUNBOOK_ALLOW_BUDGET_FAIL:-false}"

mkdir -p "$OUT_DIR"

extract_value() {
  local key="$1"
  local input="$2"
  printf '%s\n' "$input" | awk -F= -v key="$key" '$1==key {print $2}' | tail -n 1
}

{
  echo "runbook=exactly_once_million_failure"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  set +e
  PROOF_OUTPUT="$({
    REPEATS="$RUNBOOK_REPEATS" CONCURRENCY="$RUNBOOK_CONCURRENCY" \
      "$ROOT_DIR/scripts/prove_exactly_once_million.sh"
  } 2>&1)"
  PROOF_CODE=$?
  set -e
  echo "$PROOF_OUTPUT"

  PROOF_OK="$(extract_value "prove_exactly_once_million_ok" "$PROOF_OUTPUT")"
  PROOF_REPORT="$(extract_value "prove_exactly_once_million_latest" "$PROOF_OUTPUT")"
  if [[ -z "$PROOF_REPORT" ]]; then
    PROOF_REPORT="$(extract_value "prove_exactly_once_million_report" "$PROOF_OUTPUT")"
  fi
  if [[ -z "$PROOF_OK" ]]; then
    if [[ "$PROOF_CODE" -eq 0 ]]; then
      PROOF_OK="true"
    else
      PROOF_OK="false"
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

  SUMMARY_FILE="$OUT_DIR/exactly-once-million-summary.json"
  python3 - "$SUMMARY_FILE" "$PROOF_REPORT" "$PROOF_CODE" "$BUDGET_OK" "$RUNBOOK_REPEATS" "$RUNBOOK_CONCURRENCY" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
proof_report = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
proof_exit_code = int(sys.argv[3])
budget_ok = sys.argv[4].lower() == "true"
runbook_repeats = int(sys.argv[5])
runbook_concurrency = int(sys.argv[6])

proof_payload = {}
if proof_report and proof_report.exists():
    with open(proof_report, "r", encoding="utf-8") as f:
        proof_payload = json.load(f)

proof_ok = bool(proof_payload.get("ok", False)) if proof_payload else False
proof_repeats = int(proof_payload.get("repeats", runbook_repeats) or 0)
proof_concurrency = int(proof_payload.get("concurrency", runbook_concurrency) or 0)
proof_runner_exit_code = int(proof_payload.get("runner_exit_code", proof_exit_code) or proof_exit_code)

recommendation = "NO_ACTION"
if proof_exit_code != 0 or not proof_ok:
    if proof_repeats < 1_000_000:
        recommendation = "INCREASE_REPEATS_TO_MILLION_AND_RERUN"
    elif proof_runner_exit_code != 0:
        recommendation = "INVESTIGATE_EXACTLY_ONCE_PATH"
    else:
        recommendation = "INVESTIGATE_PROOF_FAILURE"
elif not budget_ok:
    recommendation = "RUN_BUDGET_FAILURE_RUNBOOK"

summary = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runbook_ok": True,
    "proof_report": str(proof_report) if proof_report else None,
    "proof_exit_code": proof_exit_code,
    "proof_ok": proof_ok,
    "proof_repeats": proof_repeats,
    "proof_concurrency": proof_concurrency,
    "proof_runner_exit_code": proof_runner_exit_code,
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
  SUMMARY_PROOF_OK="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("proof_ok") else "false")
PY
  )"
  SUMMARY_PROOF_REPEATS="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("proof_repeats", 0)))
PY
  )"
  SUMMARY_PROOF_CONCURRENCY="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("proof_concurrency", 0)))
PY
  )"
  SUMMARY_PROOF_RUNNER_EXIT_CODE="$(
    python3 - "$SUMMARY_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("proof_runner_exit_code", 0)))
PY
  )"

  RUNBOOK_OK=true
  if [[ "$PROOF_CODE" -ne 0 && "$RUNBOOK_ALLOW_PROOF_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi
  if [[ "$BUDGET_OK" != "true" && "$RUNBOOK_ALLOW_BUDGET_FAIL" != "true" ]]; then
    RUNBOOK_OK=false
  fi

  echo "exactly_once_million_proof_exit_code=$PROOF_CODE"
  echo "exactly_once_million_proof_ok=$SUMMARY_PROOF_OK"
  echo "exactly_once_million_proof_repeats=$SUMMARY_PROOF_REPEATS"
  echo "exactly_once_million_proof_concurrency=$SUMMARY_PROOF_CONCURRENCY"
  echo "exactly_once_million_proof_runner_exit_code=$SUMMARY_PROOF_RUNNER_EXIT_CODE"
  echo "runbook_budget_ok=$BUDGET_OK"
  echo "exactly_once_million_recommended_action=$RECOMMENDED_ACTION"
  echo "exactly_once_million_summary_file=$SUMMARY_FILE"
  echo "exactly_once_million_summary_latest=$LATEST_SUMMARY_FILE"
  echo "runbook_exactly_once_million_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"

  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
