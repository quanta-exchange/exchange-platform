#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/compliance}"
CONTROLS_FILE="${CONTROLS_FILE:-$ROOT_DIR/controls/controls.yaml}"
MAPPING_FILE="${MAPPING_FILE:-$ROOT_DIR/compliance/mapping.yaml}"
REQUIRE_FULL_COVERAGE="${REQUIRE_FULL_COVERAGE:-true}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --controls-file)
      CONTROLS_FILE="$2"
      shift 2
      ;;
    --mapping-file)
      MAPPING_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --require-full-coverage)
      REQUIRE_FULL_COVERAGE=true
      shift
      ;;
    --allow-partial-coverage)
      REQUIRE_FULL_COVERAGE=false
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$CONTROLS_FILE" ]]; then
  echo "controls file not found: $CONTROLS_FILE" >&2
  exit 1
fi
if [[ ! -f "$MAPPING_FILE" ]]; then
  echo "mapping file not found: $MAPPING_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/prove-mapping-coverage-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/prove-mapping-coverage-latest.json"

"$PYTHON_BIN" - "$CONTROLS_FILE" "$MAPPING_FILE" "$REPORT_FILE" "$REQUIRE_FULL_COVERAGE" <<'PY'
import json
import pathlib
import sys
from collections import Counter
from datetime import datetime, timezone

controls_file = pathlib.Path(sys.argv[1]).resolve()
mapping_file = pathlib.Path(sys.argv[2]).resolve()
report_file = pathlib.Path(sys.argv[3]).resolve()
require_full_coverage = sys.argv[4].strip().lower() == "true"

with open(controls_file, "r", encoding="utf-8") as f:
    controls_payload = json.load(f)
with open(mapping_file, "r", encoding="utf-8") as f:
    mapping_payload = json.load(f)

controls = controls_payload.get("controls", []) if isinstance(controls_payload, dict) else []
mappings = mapping_payload.get("mappings", []) if isinstance(mapping_payload, dict) else []

control_ids_raw = [str(item.get("id", "")).strip() for item in controls if isinstance(item, dict)]
mapping_ids_raw = [str(item.get("controlId", "")).strip() for item in mappings if isinstance(item, dict)]

control_ids = [cid for cid in control_ids_raw if cid]
mapping_ids = [cid for cid in mapping_ids_raw if cid]

duplicate_control_ids = sorted([cid for cid, n in Counter(control_ids).items() if n > 1])
duplicate_mapping_ids = sorted([cid for cid, n in Counter(mapping_ids).items() if n > 1])

control_id_set = set(control_ids)
mapping_id_set = set(mapping_ids)

missing_controls = sorted([cid for cid in mapping_id_set if cid not in control_id_set])
unmapped_controls = sorted([cid for cid in control_id_set if cid not in mapping_id_set])

control_by_id = {}
for item in controls:
    if not isinstance(item, dict):
        continue
    cid = str(item.get("id", "")).strip()
    if not cid or cid in control_by_id:
        continue
    control_by_id[cid] = item

unmapped_enforced_controls = sorted(
    [
        cid
        for cid in unmapped_controls
        if bool((control_by_id.get(cid) or {}).get("enforced", False))
    ]
)

total_controls_count = len(control_id_set)
mapped_controls_count = len([cid for cid in control_id_set if cid in mapping_id_set])
mapping_coverage_ratio = (
    (mapped_controls_count / total_controls_count) if total_controls_count > 0 else 1.0
)

ok = (
    len(duplicate_control_ids) == 0
    and len(duplicate_mapping_ids) == 0
    and len(missing_controls) == 0
    and (
        len(unmapped_controls) == 0
        if require_full_coverage
        else len(unmapped_enforced_controls) == 0
    )
)

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "require_full_coverage": require_full_coverage,
    "controls_file": str(controls_file),
    "mapping_file": str(mapping_file),
    "total_controls_count": total_controls_count,
    "mapped_controls_count": mapped_controls_count,
    "mapping_coverage_ratio": mapping_coverage_ratio,
    "duplicate_control_ids_count": len(duplicate_control_ids),
    "duplicate_control_ids": duplicate_control_ids,
    "duplicate_mapping_ids_count": len(duplicate_mapping_ids),
    "duplicate_mapping_ids": duplicate_mapping_ids,
    "missing_controls_count": len(missing_controls),
    "missing_controls": missing_controls,
    "unmapped_controls_count": len(unmapped_controls),
    "unmapped_controls": unmapped_controls,
    "unmapped_enforced_controls_count": len(unmapped_enforced_controls),
    "unmapped_enforced_controls": unmapped_enforced_controls,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

PROOF_OK="$("$PYTHON_BIN" - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "prove_mapping_coverage_report=${REPORT_FILE}"
echo "prove_mapping_coverage_latest=${LATEST_FILE}"
echo "prove_mapping_coverage_ok=${PROOF_OK}"

if [[ "$PROOF_OK" != "true" ]]; then
  exit 1
fi
