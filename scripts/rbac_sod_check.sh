#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RBAC_FILE="${RBAC_FILE:-$ROOT_DIR/security/rbac_roles.yaml}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/security}"
ALLOW_MISSING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rbac-file)
      RBAC_FILE="$2"
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
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/rbac-sod-check-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/rbac-sod-check-latest.json"

python3 - "$RBAC_FILE" "$REPORT_FILE" "$ALLOW_MISSING" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

rbac_file = pathlib.Path(sys.argv[1]).resolve()
report_file = pathlib.Path(sys.argv[2]).resolve()
allow_missing = sys.argv[3].lower() == "true"

errors = []
role_permissions = {}

if not rbac_file.exists():
    if not allow_missing:
        errors.append(f"rbac file missing: {rbac_file}")
else:
    with open(rbac_file, "r", encoding="utf-8") as f:
        payload = json.load(f)
    for role in payload.get("roles", []):
        name = str(role.get("name", "")).strip()
        perms = sorted(set(str(p).strip() for p in role.get("permissions", []) if str(p).strip()))
        if name:
            role_permissions[name] = perms

required_roles = {"Operator", "Approver", "Auditor", "BreakGlassCustodian"}
missing_roles = sorted(required_roles - set(role_permissions))
if missing_roles:
    errors.append(f"missing_roles={','.join(missing_roles)}")

operator = set(role_permissions.get("Operator", []))
approver = set(role_permissions.get("Approver", []))
auditor = set(role_permissions.get("Auditor", []))
custodian = set(role_permissions.get("BreakGlassCustodian", []))

if operator:
    if "run:runbooks" not in operator:
        errors.append("operator_missing_runbooks_permission")
    if "create:change_proposal" not in operator:
        errors.append("operator_missing_change_proposal_permission")
    forbidden = [p for p in operator if p.startswith("approve:") or p.startswith("enable:break_glass") or p.startswith("disable:break_glass")]
    if forbidden:
        errors.append(f"operator_forbidden_permissions={','.join(sorted(forbidden))}")

if approver:
    if "approve:change" not in approver:
        errors.append("approver_missing_approve_change")
    forbidden = [p for p in approver if p.startswith("enable:break_glass") or p.startswith("disable:break_glass")]
    if forbidden:
        errors.append(f"approver_forbidden_permissions={','.join(sorted(forbidden))}")

if auditor:
    forbidden = [p for p in auditor if not p.startswith("view:")]
    if forbidden:
        errors.append(f"auditor_non_view_permissions={','.join(sorted(forbidden))}")

if custodian:
    if "enable:break_glass" not in custodian or "disable:break_glass" not in custodian:
        errors.append("custodian_missing_break_glass_permissions")
    forbidden = [p for p in custodian if p.startswith("approve:")]
    if forbidden:
        errors.append(f"custodian_forbidden_permissions={','.join(sorted(forbidden))}")

restricted = {
    "approve:change",
    "approve:correction",
    "enable:break_glass",
    "disable:break_glass",
    "apply:change",
}
permission_owners = {}
for role_name, perms in role_permissions.items():
    for perm in perms:
        if perm in restricted:
            permission_owners.setdefault(perm, []).append(role_name)

for perm, owners in sorted(permission_owners.items()):
    if len(owners) > 1:
        errors.append(f"restricted_permission_overlap:{perm}={'|'.join(sorted(owners))}")

ok = len(errors) == 0
report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "rbac_file": str(rbac_file),
    "ok": ok,
    "errors": errors,
    "roles": role_permissions,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

RBAC_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "rbac_sod_check_report=$REPORT_FILE"
echo "rbac_sod_check_latest=$LATEST_FILE"
echo "rbac_sod_check_ok=$RBAC_OK"

if [[ "$RBAC_OK" != "true" ]]; then
  exit 1
fi
