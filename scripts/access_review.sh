#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROLES_FILE="${ROLES_FILE:-$ROOT_DIR/security/rbac_roles.yaml}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/access}"
BREAK_GLASS_AUDIT="${BREAK_GLASS_AUDIT:-$ROOT_DIR/build/break-glass/audit.log}"
CHANGES_GLOB="${CHANGES_GLOB:-$ROOT_DIR/changes/requests/*/metadata.json}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --roles-file)
      ROLES_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ ! -f "$ROLES_FILE" ]]; then
  echo "roles file not found: $ROLES_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/access-review-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/access-review-latest.json"

python3 - "$ROLES_FILE" "$BREAK_GLASS_AUDIT" "$REPORT_FILE" "$CHANGES_GLOB" <<'PY'
import glob
import json
import pathlib
import sys
from datetime import datetime, timezone

roles_file = pathlib.Path(sys.argv[1]).resolve()
break_glass_audit = pathlib.Path(sys.argv[2]).resolve()
report_file = pathlib.Path(sys.argv[3]).resolve()
changes_glob = sys.argv[4]

with open(roles_file, "r", encoding="utf-8") as f:
    roles_payload = json.load(f)

roles = roles_payload.get("roles", [])

break_glass_events = []
if break_glass_audit.exists():
    with open(break_glass_audit, "r", encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                break_glass_events.append(json.loads(raw))
            except json.JSONDecodeError:
                continue

approver_events = []
for path in sorted(glob.glob(changes_glob)):
    p = pathlib.Path(path)
    try:
        with open(p, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except Exception:
        continue
    for approval in payload.get("approvals", []) or []:
        approver_events.append(
            {
                "changeId": payload.get("changeId"),
                "approver": approval.get("approver"),
                "approvedAtUtc": approval.get("approvedAtUtc"),
            }
        )

actors = set()
for event in break_glass_events:
    actor = event.get("actor")
    if actor:
        actors.add(actor)
for event in approver_events:
    actor = event.get("approver")
    if actor:
        actors.add(actor)

role_rows = []
for role in roles:
    role_rows.append(
        {
            "name": role.get("name"),
            "permissionCount": len(role.get("permissions", []) or []),
            "permissions": role.get("permissions", []),
        }
    )

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": True,
    "role_count": len(role_rows),
    "roles": role_rows,
    "observed_actor_count": len(actors),
    "observed_actors": sorted(actors),
    "break_glass_event_count": len(break_glass_events),
    "change_approval_event_count": len(approver_events),
    "sources": {
        "roles_file": str(roles_file),
        "break_glass_audit": str(break_glass_audit),
        "changes_glob": changes_glob,
    },
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "access_review_report=${REPORT_FILE}"
echo "access_review_latest=${LATEST_FILE}"
echo "access_review_ok=true"
