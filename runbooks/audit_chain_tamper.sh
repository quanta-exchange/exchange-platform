#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/audit-chain-tamper-${TS_ID}}"
LOG_FILE="$OUT_DIR/audit-chain-tamper.log"
AUDIT_SOURCE="${AUDIT_SOURCE:-$ROOT_DIR/build/break-glass/audit.log}"

mkdir -p "$OUT_DIR"

{
  echo "runbook=audit_chain_tamper"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  "$ROOT_DIR/scripts/break_glass.sh" enable --ttl-sec 60 --actor runbook --reason audit-chain-tamper-drill >/dev/null
  "$ROOT_DIR/scripts/break_glass.sh" disable --actor runbook --reason audit-chain-tamper-drill >/dev/null

  if [[ ! -f "$AUDIT_SOURCE" ]]; then
    echo "audit source missing: $AUDIT_SOURCE" >&2
    exit 1
  fi

  SOURCE_COPY="$OUT_DIR/audit-source.log"
  TAMPER_COPY="$OUT_DIR/audit-tampered.log"
  cp "$AUDIT_SOURCE" "$SOURCE_COPY"
  cp "$AUDIT_SOURCE" "$TAMPER_COPY"

  BASELINE_OK=false
  if "$ROOT_DIR/scripts/verify_audit_chain.sh" --audit-file "$SOURCE_COPY" --out-dir "$OUT_DIR" --require-events >/dev/null; then
    BASELINE_OK=true
  fi

  python3 - "$TAMPER_COPY" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]).resolve()
lines = path.read_text(encoding="utf-8").splitlines()
target_idx = None
for idx, line in enumerate(lines):
    if not line.strip():
        continue
    row = json.loads(line)
    if isinstance(row, dict) and "hash" in row:
        target_idx = idx
        break
if target_idx is None:
    for idx, line in enumerate(lines):
        if line.strip():
            target_idx = idx
            break
if target_idx is not None:
    row = json.loads(lines[target_idx])
    row["reason"] = "tampered-audit-chain"
    lines[target_idx] = json.dumps(row, separators=(",", ":"), sort_keys=True)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

  TAMPER_DETECTED=false
  if "$ROOT_DIR/scripts/verify_audit_chain.sh" --audit-file "$TAMPER_COPY" --out-dir "$OUT_DIR/tampered" --require-events >/dev/null 2>&1; then
    TAMPER_DETECTED=false
  else
    TAMPER_DETECTED=true
  fi

  SUMMARY_JSON="$OUT_DIR/audit-chain-tamper-summary.json"
  python3 - "$SUMMARY_JSON" "$BASELINE_OK" "$TAMPER_DETECTED" "$SOURCE_COPY" "$TAMPER_COPY" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
baseline_ok = sys.argv[2].lower() == "true"
tamper_detected = sys.argv[3].lower() == "true"
source_copy = pathlib.Path(sys.argv[4]).resolve()
tamper_copy = pathlib.Path(sys.argv[5]).resolve()

ok = baseline_ok and tamper_detected
payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "baseline_ok": baseline_ok,
    "tamper_detected": tamper_detected,
    "audit_source_copy": str(source_copy),
    "audit_tampered_copy": str(tamper_copy),
}

summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  RUNBOOK_OK="$([[ "$BASELINE_OK" == "true" && "$TAMPER_DETECTED" == "true" ]] && echo true || echo false)"
  echo "runbook_audit_tamper_ok=$RUNBOOK_OK"
  echo "runbook_output_dir=$OUT_DIR"
  if [[ "$RUNBOOK_OK" != "true" ]]; then
    exit 1
  fi
} | tee "$LOG_FILE"
