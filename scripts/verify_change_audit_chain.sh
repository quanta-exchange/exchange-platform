#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT_FILE="${AUDIT_FILE:-$ROOT_DIR/build/change-audit/audit.log}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/change-audit}"
ALLOW_MISSING=true
REQUIRE_EVENTS=false
REQUIRE_CHANGE_ID=""
REQUIRE_APPLIED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit-file)
      AUDIT_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --allow-missing)
      ALLOW_MISSING=true
      shift
      ;;
    --require-events)
      REQUIRE_EVENTS=true
      shift
      ;;
    --require-change-id)
      REQUIRE_CHANGE_ID="$2"
      shift 2
      ;;
    --require-applied)
      REQUIRE_APPLIED=true
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
REPORT_FILE="$OUT_DIR/verify-change-audit-chain-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/verify-change-audit-chain-latest.json"

python3 - "$AUDIT_FILE" "$REPORT_FILE" "$ALLOW_MISSING" "$REQUIRE_EVENTS" "$REQUIRE_CHANGE_ID" "$REQUIRE_APPLIED" <<'PY'
import hashlib
import json
import pathlib
import sys
from datetime import datetime, timezone

audit_file = pathlib.Path(sys.argv[1]).resolve()
report_file = pathlib.Path(sys.argv[2]).resolve()
allow_missing = sys.argv[3].lower() == "true"
require_events = sys.argv[4].lower() == "true"
require_change_id = sys.argv[5] or None
require_applied = sys.argv[6].lower() == "true"

errors = []
entry_count = 0
legacy_rows = 0
chained_rows = 0
head_hash = "GENESIS"
mode = "empty"
exists = audit_file.exists()

events_by_change = {}

if not exists:
    if not allow_missing:
        errors.append("audit file missing")
    mode = "missing"
else:
    prev_hash = "GENESIS"
    with open(audit_file, "r", encoding="utf-8") as f:
        for idx, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            entry_count += 1
            try:
                row = json.loads(line)
            except Exception as exc:
                errors.append(f"line {idx}: invalid json ({exc})")
                continue

            event = str(row.get("event", ""))
            payload = row.get("payload", {}) if isinstance(row, dict) else {}
            change_id = None
            if isinstance(payload, dict):
                cid = payload.get("changeId")
                if cid is not None:
                    change_id = str(cid)
            if change_id:
                events_by_change.setdefault(change_id, []).append(event)

            has_chain_fields = isinstance(row, dict) and "hash" in row and "prevHash" in row
            if has_chain_fields:
                row_hash = str(row.get("hash", ""))
                prev_field = str(row.get("prevHash", ""))
                if prev_field == "LEGACY" and chained_rows == 0 and legacy_rows > 0:
                    prev_hash = "LEGACY"
                body = dict(row)
                body.pop("hash", None)
                canonical = json.dumps(body, separators=(",", ":"), sort_keys=True)
                derived = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
                if derived != row_hash:
                    errors.append(f"line {idx}: hash mismatch")
                if prev_field != prev_hash:
                    errors.append(
                        f"line {idx}: prevHash mismatch (expected={prev_hash}, actual={prev_field})"
                    )
                prev_hash = row_hash
                chained_rows += 1
            else:
                canonical = json.dumps(row, separators=(",", ":"), sort_keys=True)
                prev_hash = hashlib.sha256(
                    (prev_hash + "\n" + canonical).encode("utf-8")
                ).hexdigest()
                legacy_rows += 1

    head_hash = prev_hash
    if chained_rows > 0 and legacy_rows > 0:
        mode = "mixed"
    elif chained_rows > 0:
        mode = "chained"
    elif legacy_rows > 0:
        mode = "legacy"
    else:
        mode = "empty"

if require_events and entry_count == 0:
    errors.append("no audit events found while --require-events is enabled")

required_change_events = []
if require_change_id:
    required_change_events = events_by_change.get(require_change_id, [])
    if not required_change_events:
        errors.append(f"no audit events for changeId={require_change_id}")
    if require_applied and "change_applied" not in required_change_events:
        errors.append(f"missing change_applied event for changeId={require_change_id}")

ok = len(errors) == 0
payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "audit_file": str(audit_file),
    "exists": exists,
    "entry_count": entry_count,
    "legacy_rows": legacy_rows,
    "chained_rows": chained_rows,
    "mode": mode,
    "head_hash": head_hash,
    "require_change_id": require_change_id,
    "require_applied": require_applied,
    "required_change_events": required_change_events,
    "ok": ok,
    "errors": errors,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

VERIFY_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

HEAD_HASH="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("head_hash", ""))
PY
)"

echo "verify_change_audit_chain_report=$REPORT_FILE"
echo "verify_change_audit_chain_latest=$LATEST_FILE"
echo "verify_change_audit_chain_head=$HEAD_HASH"
echo "verify_change_audit_chain_ok=$VERIFY_OK"

if [[ "$VERIFY_OK" != "true" ]]; then
  exit 1
fi
