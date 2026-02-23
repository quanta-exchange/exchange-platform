#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib_audit_chain.sh"
CHANGE_DIR=""
APPLY_COMMAND=""
SKIP_VERIFICATION=false
APPLIED_BY="${APPLIED_BY:-unknown}"
CHANGE_AUDIT_FILE="${CHANGE_AUDIT_FILE:-$ROOT_DIR/build/change-audit/audit.log}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --change-dir)
      CHANGE_DIR="$2"
      shift 2
      ;;
    --command)
      APPLY_COMMAND="$2"
      shift 2
      ;;
    --skip-verification)
      SKIP_VERIFICATION=true
      shift
      ;;
    --applied-by)
      APPLIED_BY="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$CHANGE_DIR" ]]; then
  echo "missing --change-dir" >&2
  exit 1
fi
if [[ -z "$APPLY_COMMAND" ]]; then
  echo "missing --command" >&2
  exit 1
fi

META_FILE="$CHANGE_DIR/metadata.json"
if [[ ! -f "$META_FILE" ]]; then
  echo "metadata not found: $META_FILE" >&2
  exit 1
fi

python3 - "$META_FILE" <<'PY'
import json
import sys

meta_file = sys.argv[1]
with open(meta_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

risk = str(payload.get("riskLevel", "MEDIUM")).upper()
approvals = payload.get("approvals", []) or []
required = 2 if risk == "HIGH" else 1

if len(approvals) < required:
    print(f"insufficient approvals: have={len(approvals)} required={required}", file=sys.stderr)
    sys.exit(1)

status = str(payload.get("status", "DRAFT"))
if status not in {"APPROVED", "PENDING_APPROVAL"}:
    print(f"change status not applyable: {status}", file=sys.stderr)
    sys.exit(1)
PY

RUN_TS="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="$CHANGE_DIR/apply-$RUN_TS"
mkdir -p "$OUT_DIR"
APPLY_LOG="$OUT_DIR/apply.log"
VERIFY_LOG="$OUT_DIR/verify.log"

(
  cd "$ROOT_DIR"
  bash -lc "$APPLY_COMMAND"
) >"$APPLY_LOG" 2>&1

VERIFICATION_SUMMARY=""
if [[ "$SKIP_VERIFICATION" == "false" ]]; then
  "$ROOT_DIR/scripts/verification_factory.sh" >"$VERIFY_LOG" 2>&1
  VERIFICATION_SUMMARY="$(grep -E '^verification_summary=' "$VERIFY_LOG" | tail -n 1 | sed 's/^verification_summary=//')"
fi

python3 - "$META_FILE" "$APPLY_COMMAND" "$RUN_TS" "$OUT_DIR" "$VERIFICATION_SUMMARY" "$SKIP_VERIFICATION" <<'PY'
import json
import sys
from datetime import datetime, timezone

meta_file = sys.argv[1]
apply_command = sys.argv[2]
run_ts = sys.argv[3]
out_dir = sys.argv[4]
verification_summary = sys.argv[5]
skip_verification = sys.argv[6].lower() == "true"

with open(meta_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

payload["status"] = "APPLIED"
payload["applied"] = {
    "appliedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "applyRunId": run_ts,
    "command": apply_command,
    "outputDir": out_dir,
    "verificationSkipped": skip_verification,
    "verificationSummary": verification_summary or None,
}

with open(meta_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

CHANGE_ID="$(
  python3 - "$META_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("changeId", "unknown"))
PY
)"

AUDIT_PAYLOAD="$(
  python3 - "$CHANGE_ID" "$CHANGE_DIR" "$OUT_DIR" "$SKIP_VERIFICATION" "$VERIFICATION_SUMMARY" <<'PY'
import json
import sys
print(json.dumps({
    "changeId": sys.argv[1],
    "changeDir": sys.argv[2],
    "outputDir": sys.argv[3],
    "verificationSkipped": sys.argv[4].lower() == "true",
    "verificationSummary": sys.argv[5] or None,
}, separators=(",", ":"), sort_keys=True))
PY
)"
audit_chain_append "$CHANGE_AUDIT_FILE" "change_applied" "$APPLIED_BY" "$APPLY_COMMAND" "$AUDIT_PAYLOAD"

echo "change_apply_success=true"
echo "change_apply_log=$APPLY_LOG"
if [[ "$SKIP_VERIFICATION" == "false" ]]; then
  echo "change_verify_log=$VERIFY_LOG"
  echo "change_verification_summary=$VERIFICATION_SUMMARY"
fi
echo "change_audit_file=$CHANGE_AUDIT_FILE"
