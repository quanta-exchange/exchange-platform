#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/adversarial}"
LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
EXACTLY_ONCE_REPEATS="${EXACTLY_ONCE_REPEATS:-2000}"
EXACTLY_ONCE_CONCURRENCY="${EXACTLY_ONCE_CONCURRENCY:-32}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --ledger-base-url)
      LEDGER_BASE_URL="$2"
      shift 2
      ;;
    --exactly-once-repeats)
      EXACTLY_ONCE_REPEATS="$2"
      shift 2
      ;;
    --exactly-once-concurrency)
      EXACTLY_ONCE_CONCURRENCY="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/$TS_ID"
LOG_DIR="$RUN_DIR/logs"
REPORT_FILE="$RUN_DIR/adversarial-tests.json"
LATEST_FILE="$OUT_DIR/adversarial-tests-latest.json"
mkdir -p "$LOG_DIR"

run_step() {
  local name="$1"
  shift
  local logfile="$LOG_DIR/${name}.log"
  set +e
  "$@" >"$logfile" 2>&1
  local code=$?
  set -e
  if [[ "$code" -eq 0 ]]; then
    echo "step_${name}=pass"
    return 0
  fi
  echo "step_${name}=fail"
  return 1
}

status_policy="fail"
status_ws="fail"
status_ws_resume="fail"
status_candles="fail"
status_snapshot_verify="fail"
status_exactly_once="skip"
exactly_once_reason="ledger_not_ready"

if run_step "policy_smoke" "$ROOT_DIR/scripts/policy_smoke.sh"; then
  status_policy="pass"
fi

if run_step "ws_smoke" "$ROOT_DIR/scripts/ws_smoke.sh"; then
  status_ws="pass"
fi

if run_step "ws_resume_smoke" "$ROOT_DIR/scripts/ws_resume_smoke.sh"; then
  status_ws_resume="pass"
fi

if run_step "prove_candles" "$ROOT_DIR/scripts/prove_candles.sh"; then
  status_candles="pass"
fi

if run_step "snapshot_verify" "$ROOT_DIR/scripts/snapshot_verify.sh"; then
  status_snapshot_verify="pass"
fi

if curl -fsS "${LEDGER_BASE_URL}/readyz" >/dev/null 2>&1; then
  exactly_once_reason=""
  if run_step "exactly_once_stress" env LEDGER_BASE_URL="${LEDGER_BASE_URL}" REPEATS="${EXACTLY_ONCE_REPEATS}" CONCURRENCY="${EXACTLY_ONCE_CONCURRENCY}" "$ROOT_DIR/scripts/exactly_once_stress.sh"; then
    status_exactly_once="pass"
  else
    status_exactly_once="fail"
  fi
fi

python3 - "$REPORT_FILE" "$status_policy" "$status_ws" "$status_ws_resume" "$status_candles" "$status_snapshot_verify" "$status_exactly_once" "$exactly_once_reason" "$LOG_DIR" "$LEDGER_BASE_URL" "$EXACTLY_ONCE_REPEATS" "$EXACTLY_ONCE_CONCURRENCY" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
status_policy = sys.argv[2]
status_ws = sys.argv[3]
status_ws_resume = sys.argv[4]
status_candles = sys.argv[5]
status_snapshot_verify = sys.argv[6]
status_exactly_once = sys.argv[7]
exactly_once_reason = sys.argv[8]
log_dir = pathlib.Path(sys.argv[9]).resolve()
ledger_base_url = sys.argv[10]
exactly_once_repeats = int(sys.argv[11])
exactly_once_concurrency = int(sys.argv[12])

steps = [
    {"name": "policy_smoke", "status": status_policy},
    {"name": "ws_smoke", "status": status_ws},
    {"name": "ws_resume_smoke", "status": status_ws_resume},
    {"name": "prove_candles", "status": status_candles},
    {"name": "snapshot_verify", "status": status_snapshot_verify},
    {
        "name": "exactly_once_stress",
        "status": status_exactly_once,
        "skip_reason": exactly_once_reason or None,
    },
]

ok = (
    status_policy == "pass"
    and status_ws == "pass"
    and status_ws_resume == "pass"
    and status_candles == "pass"
    and status_snapshot_verify == "pass"
    and status_exactly_once in {"pass", "skip"}
)

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "ledger_base_url": ledger_base_url,
    "exactly_once_params": {
        "repeats": exactly_once_repeats,
        "concurrency": exactly_once_concurrency,
    },
    "steps": steps,
    "logs_dir": str(log_dir),
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "adversarial_tests_report=${REPORT_FILE}"
echo "adversarial_tests_latest=${LATEST_FILE}"
echo "adversarial_tests_ok=$([[ "${status_policy}" == "pass" && "${status_ws}" == "pass" && "${status_ws_resume}" == "pass" && "${status_candles}" == "pass" && "${status_snapshot_verify}" == "pass" && ( "${status_exactly_once}" == "pass" || "${status_exactly_once}" == "skip" ) ]] && echo true || echo false)"

if [[ "${status_policy}" != "pass" || "${status_ws}" != "pass" || "${status_ws_resume}" != "pass" || "${status_candles}" != "pass" || "${status_snapshot_verify}" != "pass" ]]; then
  exit 1
fi
if [[ "${status_exactly_once}" == "fail" ]]; then
  exit 1
fi
