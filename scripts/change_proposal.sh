#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHANGE_ROOT="${CHANGE_ROOT:-$ROOT_DIR/changes/requests}"
TEMPLATE_FILE="${TEMPLATE_FILE:-$ROOT_DIR/changes/templates/change-proposal.md}"

CHANGE_ID="${CHANGE_ID:-chg-$(date -u +"%Y%m%dT%H%M%SZ")}"
TITLE="${TITLE:-Untitled Change}"
RISK_LEVEL="${RISK_LEVEL:-MEDIUM}"
REQUESTED_BY="${REQUESTED_BY:-unknown}"
SUMMARY="${SUMMARY:-No summary provided}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --change-id)
      CHANGE_ID="$2"
      shift 2
      ;;
    --title)
      TITLE="$2"
      shift 2
      ;;
    --risk-level)
      RISK_LEVEL="$2"
      shift 2
      ;;
    --requested-by)
      REQUESTED_BY="$2"
      shift 2
      ;;
    --summary)
      SUMMARY="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

case "$RISK_LEVEL" in
  LOW|MEDIUM|HIGH) ;;
  *)
    echo "risk level must be LOW|MEDIUM|HIGH" >&2
    exit 1
    ;;
esac

CHANGE_DIR="$CHANGE_ROOT/$CHANGE_ID"
PROPOSAL_FILE="$CHANGE_DIR/proposal.md"
META_FILE="$CHANGE_DIR/metadata.json"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ -e "$CHANGE_DIR" ]]; then
  echo "change already exists: $CHANGE_DIR" >&2
  exit 1
fi

mkdir -p "$CHANGE_DIR"

if [[ -f "$TEMPLATE_FILE" ]]; then
  cp "$TEMPLATE_FILE" "$PROPOSAL_FILE"
else
  cat > "$PROPOSAL_FILE" <<EOF
# Change Proposal

- change_id: \`$CHANGE_ID\`
- title: \`$TITLE\`
- risk_level: \`$RISK_LEVEL\`
- requested_by: \`$REQUESTED_BY\`
- requested_at_utc: \`$TS\`

## Summary
$SUMMARY
EOF
fi

python3 - "$PROPOSAL_FILE" "$CHANGE_ID" "$TITLE" "$RISK_LEVEL" "$REQUESTED_BY" "$TS" "$SUMMARY" <<'PY'
import pathlib
import re
import sys

proposal_path = pathlib.Path(sys.argv[1])
change_id = sys.argv[2]
title = sys.argv[3]
risk_level = sys.argv[4]
requested_by = sys.argv[5]
requested_at = sys.argv[6]
summary = sys.argv[7]

text = proposal_path.read_text(encoding="utf-8")
text = re.sub(r"<change-id>", change_id, text)
text = re.sub(r"<title>", title, text)
text = re.sub(r"LOW\|MEDIUM\|HIGH", risk_level, text)
text = re.sub(r"<requester>", requested_by, text)
text = re.sub(r"<timestamp>", requested_at, text)
text = re.sub(r"<one-line summary>", summary, text)
proposal_path.write_text(text, encoding="utf-8")
PY

python3 - "$META_FILE" "$CHANGE_ID" "$TITLE" "$RISK_LEVEL" "$REQUESTED_BY" "$TS" "$SUMMARY" <<'PY'
import json
import sys

meta_file = sys.argv[1]
payload = {
    "changeId": sys.argv[2],
    "title": sys.argv[3],
    "riskLevel": sys.argv[4],
    "requestedBy": sys.argv[5],
    "requestedAtUtc": sys.argv[6],
    "summary": sys.argv[7],
    "status": "DRAFT",
    "approvals": [],
    "applied": None,
}
with open(meta_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "change_proposal_created=true"
echo "change_id=$CHANGE_ID"
echo "change_dir=$CHANGE_DIR"
echo "change_proposal_file=$PROPOSAL_FILE"
echo "change_metadata_file=$META_FILE"
