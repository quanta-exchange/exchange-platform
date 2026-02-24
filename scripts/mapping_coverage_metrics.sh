#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/metrics}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
PROM_FILE="$OUT_DIR/mapping-coverage-${TS_ID}.prom"
PROM_LATEST="$OUT_DIR/mapping-coverage-latest.prom"
JSON_FILE="$OUT_DIR/mapping-coverage-${TS_ID}.json"
JSON_LATEST="$OUT_DIR/mapping-coverage-latest.json"

"$PYTHON_BIN" - "$ROOT_DIR" "$PROM_FILE" "$JSON_FILE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1]).resolve()
prom_file = pathlib.Path(sys.argv[2]).resolve()
json_file = pathlib.Path(sys.argv[3]).resolve()

coverage_path = root / "build/compliance/prove-mapping-coverage-latest.json"
compliance_path = root / "build/compliance/compliance-evidence-latest.json"
runbook_path = root / "build/runbooks/mapping-coverage-latest.json"
now = datetime.now(timezone.utc)


def safe_load(path: pathlib.Path):
    if not path.exists():
        return None, f"missing:{path}"
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f), None
    except Exception as exc:  # pragma: no cover
        return None, f"parse_error:{path}:{exc}"


coverage_payload, coverage_err = safe_load(coverage_path)
compliance_payload, compliance_err = safe_load(compliance_path)
runbook_payload, runbook_err = safe_load(runbook_path)

error_messages = []
if coverage_err:
    error_messages.append(coverage_err)
if compliance_err:
    error_messages.append(compliance_err)
if runbook_err:
    error_messages.append(runbook_err)

export_ok = coverage_payload is not None

coverage_ok = bool((coverage_payload or {}).get("ok", False))
require_full_coverage = bool((coverage_payload or {}).get("require_full_coverage", False))
mapping_coverage_ratio = float((coverage_payload or {}).get("mapping_coverage_ratio", 0.0) or 0.0)
missing_controls_count = int((coverage_payload or {}).get("missing_controls_count", 0) or 0)
unmapped_controls_count = int((coverage_payload or {}).get("unmapped_controls_count", 0) or 0)
unmapped_enforced_controls_count = int(
    (coverage_payload or {}).get("unmapped_enforced_controls_count", 0) or 0
)
duplicate_control_ids_count = int(
    (coverage_payload or {}).get("duplicate_control_ids_count", 0) or 0
)
duplicate_mapping_ids_count = int(
    (coverage_payload or {}).get("duplicate_mapping_ids_count", 0) or 0
)

compliance_ok = bool((compliance_payload or {}).get("ok", False))
compliance_require_full_mapping = bool(
    (compliance_payload or {}).get("require_full_mapping", False)
)
compliance_mapping_coverage_ratio = float(
    (compliance_payload or {}).get("mapping_coverage_ratio", 0.0) or 0.0
)

runbook_proof_ok = bool((runbook_payload or {}).get("proof_ok", False))
runbook_recommended_action = str(
    (runbook_payload or {}).get("recommended_action", "NO_ACTION")
)

health_ok = (
    coverage_ok
    and mapping_coverage_ratio >= 1.0
    and missing_controls_count == 0
    and unmapped_enforced_controls_count == 0
    and duplicate_control_ids_count == 0
    and duplicate_mapping_ids_count == 0
)

safe_action = runbook_recommended_action.replace("\\", "\\\\").replace('"', '\\"')

lines = []
lines.append("# HELP mapping_coverage_overall_ok Whether mapping coverage health is fully green.")
lines.append("# TYPE mapping_coverage_overall_ok gauge")
lines.append("# HELP mapping_coverage_export_ok Whether mapping coverage metrics export completed successfully.")
lines.append("# TYPE mapping_coverage_export_ok gauge")
lines.append("# HELP mapping_coverage_ratio Controls-to-mapping coverage ratio from prove-mapping-coverage.")
lines.append("# TYPE mapping_coverage_ratio gauge")
lines.append("# HELP mapping_coverage_missing_controls_count Count of mapping entries that reference unknown controls.")
lines.append("# TYPE mapping_coverage_missing_controls_count gauge")
lines.append("# HELP mapping_coverage_unmapped_controls_count Count of controls missing compliance mappings.")
lines.append("# TYPE mapping_coverage_unmapped_controls_count gauge")
lines.append("# HELP mapping_coverage_unmapped_enforced_controls_count Count of enforced controls missing mappings.")
lines.append("# TYPE mapping_coverage_unmapped_enforced_controls_count gauge")
lines.append("# HELP mapping_coverage_duplicate_control_ids_count Duplicate control IDs in controls catalog.")
lines.append("# TYPE mapping_coverage_duplicate_control_ids_count gauge")
lines.append("# HELP mapping_coverage_duplicate_mapping_ids_count Duplicate mapping IDs in compliance mapping.")
lines.append("# TYPE mapping_coverage_duplicate_mapping_ids_count gauge")
lines.append("# HELP mapping_coverage_require_full_coverage Whether prove-mapping-coverage was in full-coverage mode.")
lines.append("# TYPE mapping_coverage_require_full_coverage gauge")
lines.append("# HELP mapping_coverage_compliance_ok Latest compliance evidence status.")
lines.append("# TYPE mapping_coverage_compliance_ok gauge")
lines.append("# HELP mapping_coverage_compliance_ratio Mapping coverage ratio from compliance evidence.")
lines.append("# TYPE mapping_coverage_compliance_ratio gauge")
lines.append("# HELP mapping_coverage_runbook_proof_ok Latest mapping-coverage runbook proof status.")
lines.append("# TYPE mapping_coverage_runbook_proof_ok gauge")
lines.append("# HELP mapping_coverage_runbook_recommended_action Current recommended action from mapping-coverage runbook.")
lines.append("# TYPE mapping_coverage_runbook_recommended_action gauge")
lines.append(f"mapping_coverage_overall_ok {1 if health_ok else 0}")
lines.append(f"mapping_coverage_export_ok {1 if export_ok else 0}")
lines.append(f"mapping_coverage_ratio {mapping_coverage_ratio}")
lines.append(f"mapping_coverage_missing_controls_count {missing_controls_count}")
lines.append(f"mapping_coverage_unmapped_controls_count {unmapped_controls_count}")
lines.append(
    "mapping_coverage_unmapped_enforced_controls_count "
    f"{unmapped_enforced_controls_count}"
)
lines.append(f"mapping_coverage_duplicate_control_ids_count {duplicate_control_ids_count}")
lines.append(f"mapping_coverage_duplicate_mapping_ids_count {duplicate_mapping_ids_count}")
lines.append(f"mapping_coverage_require_full_coverage {1 if require_full_coverage else 0}")
lines.append(f"mapping_coverage_compliance_ok {1 if compliance_ok else 0}")
lines.append(f"mapping_coverage_compliance_ratio {compliance_mapping_coverage_ratio}")
lines.append(f"mapping_coverage_runbook_proof_ok {1 if runbook_proof_ok else 0}")
lines.append(
    'mapping_coverage_runbook_recommended_action'
    f'{{action="{safe_action}"}} 1'
)

prom_file.parent.mkdir(parents=True, exist_ok=True)
with open(prom_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

payload = {
    "generated_at_utc": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": health_ok,
    "health_ok": health_ok,
    "export_ok": export_ok,
    "error_count": len(error_messages),
    "errors": error_messages,
    "coverage_report_path": str(coverage_path),
    "coverage_ok": coverage_ok,
    "require_full_coverage": require_full_coverage,
    "mapping_coverage_ratio": mapping_coverage_ratio,
    "missing_controls_count": missing_controls_count,
    "unmapped_controls_count": unmapped_controls_count,
    "unmapped_enforced_controls_count": unmapped_enforced_controls_count,
    "duplicate_control_ids_count": duplicate_control_ids_count,
    "duplicate_mapping_ids_count": duplicate_mapping_ids_count,
    "compliance_report_path": str(compliance_path),
    "compliance_ok": compliance_ok,
    "compliance_require_full_mapping": compliance_require_full_mapping,
    "compliance_mapping_coverage_ratio": compliance_mapping_coverage_ratio,
    "runbook_report_path": str(runbook_path),
    "runbook_proof_ok": runbook_proof_ok,
    "runbook_recommended_action": runbook_recommended_action,
    "prom_file": str(prom_file),
}
with open(json_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$PROM_FILE" "$PROM_LATEST"
cp "$JSON_FILE" "$JSON_LATEST"

METRICS_OK="$("$PYTHON_BIN" - "$JSON_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("export_ok") else "false")
PY
)"

echo "mapping_coverage_metrics_report=$JSON_FILE"
echo "mapping_coverage_metrics_latest=$JSON_LATEST"
echo "mapping_coverage_metrics_prom=$PROM_FILE"
echo "mapping_coverage_metrics_prom_latest=$PROM_LATEST"
echo "mapping_coverage_metrics_ok=$METRICS_OK"

if [[ "$METRICS_OK" != "true" ]]; then
  exit 1
fi
