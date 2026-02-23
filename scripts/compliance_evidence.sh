#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAPPING_FILE="${MAPPING_FILE:-$ROOT_DIR/compliance/mapping.yaml}"
CONTROLS_REPORT="${CONTROLS_REPORT:-$ROOT_DIR/build/controls/controls-check-latest.json}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/compliance}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mapping-file)
      MAPPING_FILE="$2"
      shift 2
      ;;
    --controls-report)
      CONTROLS_REPORT="$2"
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

if [[ ! -f "$MAPPING_FILE" ]]; then
  echo "mapping file not found: $MAPPING_FILE" >&2
  exit 1
fi
if [[ ! -f "$CONTROLS_REPORT" ]]; then
  echo "controls report not found: $CONTROLS_REPORT (run make controls-check first)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/compliance-evidence-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/compliance-evidence-latest.json"

python3 - "$MAPPING_FILE" "$CONTROLS_REPORT" "$REPORT_FILE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

mapping_file = pathlib.Path(sys.argv[1]).resolve()
controls_file = pathlib.Path(sys.argv[2]).resolve()
report_file = pathlib.Path(sys.argv[3]).resolve()

with open(mapping_file, "r", encoding="utf-8") as f:
    mappings = json.load(f).get("mappings", [])

with open(controls_file, "r", encoding="utf-8") as f:
    controls_payload = json.load(f)

controls_by_id = {r.get("id"): r for r in controls_payload.get("results", [])}

rows = []
missing_controls = []
failed_controls = []
for item in mappings:
    cid = item.get("controlId")
    row = {
        "controlId": cid,
        "frameworks": item.get("frameworks", []),
        "description": item.get("description", ""),
        "existsInCatalog": False,
        "controlOk": False,
        "enforced": False,
        "missingEvidence": [],
    }
    control = controls_by_id.get(cid)
    if control is None:
        missing_controls.append(cid)
        rows.append(row)
        continue

    row["existsInCatalog"] = True
    row["controlOk"] = bool(control.get("ok", False))
    row["enforced"] = bool(control.get("enforced", False))
    row["missingEvidence"] = list(control.get("missing_evidence", []) or [])
    if row["enforced"] and not row["controlOk"]:
        failed_controls.append(cid)
    rows.append(row)

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(missing_controls) == 0 and len(failed_controls) == 0,
    "mapping_count": len(rows),
    "missing_controls": missing_controls,
    "failed_enforced_controls": failed_controls,
    "controls_report_source": str(controls_file),
    "mappings": rows,
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

COMPLIANCE_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "compliance_evidence_report=${REPORT_FILE}"
echo "compliance_evidence_latest=${LATEST_FILE}"
echo "compliance_evidence_ok=${COMPLIANCE_OK}"

if [[ "${COMPLIANCE_OK}" != "true" ]]; then
  exit 1
fi
