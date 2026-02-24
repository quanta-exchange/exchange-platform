#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/release-gate-smoke}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/release-gate-fallback-smoke-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/release-gate-fallback-smoke-latest.json"
LOG_FILE="$OUT_DIR/release-gate-fallback-smoke-${TS_ID}.log"

set +e
GATE_OUTPUT="$("$ROOT_DIR/scripts/release_gate.sh" 2>&1)"
GATE_EXIT_CODE=$?
set -e

printf '%s\n' "$GATE_OUTPUT" > "$LOG_FILE"
echo "$GATE_OUTPUT"

GATE_LATEST="$(printf '%s\n' "$GATE_OUTPUT" | awk -F= '/^release_gate_latest=/{print $2}' | tail -n 1)"
if [[ -z "$GATE_LATEST" ]]; then
  GATE_LATEST="$ROOT_DIR/build/release-gate/release-gate-latest.json"
fi

python3 - "$REPORT_FILE" "$GATE_LATEST" "$GATE_EXIT_CODE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
gate_latest = pathlib.Path(sys.argv[2]).resolve()
gate_exit_code = int(sys.argv[3])

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
    "ok": False,
    "release_gate_exit_code": gate_exit_code,
    "release_gate_latest": str(gate_latest),
    "release_gate_ok": None,
    "required_fields": required_fields,
    "missing_fields": list(required_fields),
}

if gate_latest.exists():
    with open(gate_latest, "r", encoding="utf-8") as f:
        gate_payload = json.load(f)
    missing = [field for field in required_fields if gate_payload.get(field) is None]
    payload["release_gate_ok"] = bool(gate_payload.get("ok", False))
    payload["missing_fields"] = missing
    payload["ok"] = len(missing) == 0
else:
    payload["missing_fields"].append("release_gate_latest_missing")

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

SMOKE_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "release_gate_fallback_smoke_report=${REPORT_FILE}"
echo "release_gate_fallback_smoke_latest=${LATEST_FILE}"
echo "release_gate_fallback_smoke_ok=${SMOKE_OK}"

if [[ "${SMOKE_OK}" != "true" ]]; then
  exit 1
fi

