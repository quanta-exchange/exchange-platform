#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib_audit_chain.sh"
CHANGE_DIR=""
APPROVER="${APPROVER:-}"
NOTE="${NOTE:-approved}"
CHANGE_AUDIT_FILE="${CHANGE_AUDIT_FILE:-$ROOT_DIR/build/change-audit/audit.log}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --change-dir)
      CHANGE_DIR="$2"
      shift 2
      ;;
    --approver)
      APPROVER="$2"
      shift 2
      ;;
    --note)
      NOTE="$2"
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
if [[ -z "$APPROVER" ]]; then
  echo "missing --approver" >&2
  exit 1
fi

META_FILE="$CHANGE_DIR/metadata.json"
if [[ ! -f "$META_FILE" ]]; then
  echo "metadata not found: $META_FILE" >&2
  exit 1
fi

python3 - "$META_FILE" "$APPROVER" "$NOTE" <<'PY'
import json
import sys
from datetime import datetime, timezone

meta_file = sys.argv[1]
approver = sys.argv[2]
note = sys.argv[3]

with open(meta_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

approvals = payload.get("approvals", []) or []
for row in approvals:
    if row.get("approver") == approver:
        print(f"approver already recorded: {approver}", file=sys.stderr)
        sys.exit(1)

approvals.append(
    {
        "approver": approver,
        "note": note,
        "approvedAtUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
)
payload["approvals"] = approvals

risk = str(payload.get("riskLevel", "MEDIUM")).upper()
required = 2 if risk == "HIGH" else 1
if len(approvals) >= required:
    payload["status"] = "APPROVED"
else:
    payload["status"] = "PENDING_APPROVAL"

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
  python3 - "$CHANGE_ID" "$CHANGE_DIR" "$NOTE" <<'PY'
import json
import sys
print(json.dumps({
    "changeId": sys.argv[1],
    "changeDir": sys.argv[2],
    "approvalNote": sys.argv[3],
}, separators=(",", ":"), sort_keys=True))
PY
)"
audit_chain_append "$CHANGE_AUDIT_FILE" "change_approved" "$APPROVER" "$NOTE" "$AUDIT_PAYLOAD"

echo "change_approval_recorded=true"
echo "change_metadata_file=$META_FILE"
echo "change_audit_file=$CHANGE_AUDIT_FILE"
