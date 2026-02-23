#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/compliance}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/prove-mapping-integrity-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/prove-mapping-integrity-latest.json"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ORIG_MAPPING="$ROOT_DIR/compliance/mapping.yaml"
DUP_MAPPING="$WORK_DIR/mapping-dup.json"
DUP_OUT_DIR="$WORK_DIR/dup-out"
REAL_OUT_DIR="$WORK_DIR/real-out"
DUP_LOG="$WORK_DIR/dup.log"
REAL_LOG="$WORK_DIR/real.log"

"$ROOT_DIR/scripts/controls_check.sh" >/dev/null

DUP_ID="$($PYTHON_BIN - "$ORIG_MAPPING" "$DUP_MAPPING" <<'PY'
import copy
import json
import sys

src = sys.argv[1]
out = sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    payload = json.load(f)

mappings = list(payload.get('mappings', []))
if not mappings:
    raise SystemExit('mapping_file_empty')

dup_entry = copy.deepcopy(mappings[0])
dup_id = str(dup_entry.get('controlId', '') or '')
mappings.append(dup_entry)
payload['mappings'] = mappings

with open(out, 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write('\n')

print(dup_id)
PY
)"

set +e
"$ROOT_DIR/scripts/compliance_evidence.sh" \
  --mapping-file "$DUP_MAPPING" \
  --out-dir "$DUP_OUT_DIR" >"$DUP_LOG" 2>&1
DUP_EXIT_CODE=$?
set -e

set +e
"$ROOT_DIR/scripts/compliance_evidence.sh" \
  --mapping-file "$ORIG_MAPPING" \
  --out-dir "$REAL_OUT_DIR" >"$REAL_LOG" 2>&1
REAL_EXIT_CODE=$?
set -e

$PYTHON_BIN - "$REPORT_FILE" "$DUP_OUT_DIR/compliance-evidence-latest.json" "$REAL_OUT_DIR/compliance-evidence-latest.json" "$DUP_EXIT_CODE" "$REAL_EXIT_CODE" "$DUP_ID" "$DUP_LOG" "$REAL_LOG" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
dup_report_file = pathlib.Path(sys.argv[2]).resolve()
real_report_file = pathlib.Path(sys.argv[3]).resolve()
dup_exit_code = int(sys.argv[4])
real_exit_code = int(sys.argv[5])
expected_dup_id = sys.argv[6]
dup_log = sys.argv[7]
real_log = sys.argv[8]

def read_json(path):
    if not path.exists():
        return {}
    with open(path, 'r', encoding='utf-8') as f:
        return json.load(f)

dup_payload = read_json(dup_report_file)
real_payload = read_json(real_report_file)

dup_ids = list(dup_payload.get('duplicate_mapping_ids', []) or [])
dup_count = int(dup_payload.get('duplicate_mapping_ids_count', 0) or 0)
real_dup_count = int(real_payload.get('duplicate_mapping_ids_count', 0) or 0)

ok = (
    dup_exit_code != 0
    and dup_count >= 1
    and (expected_dup_id in dup_ids if expected_dup_id else True)
    and real_exit_code == 0
    and real_dup_count == 0
)

payload = {
    'generated_at_utc': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'ok': ok,
    'duplicate_probe': {
      'exit_code': dup_exit_code,
      'report': str(dup_report_file),
      'duplicate_mapping_ids_count': dup_count,
      'duplicate_mapping_ids': dup_ids,
      'expected_duplicate_id': expected_dup_id,
      'log': dup_log,
    },
    'baseline_probe': {
      'exit_code': real_exit_code,
      'report': str(real_report_file),
      'duplicate_mapping_ids_count': real_dup_count,
      'log': real_log,
    }
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write('\n')
PY

cp "$REPORT_FILE" "$LATEST_FILE"

PROOF_OK="$($PYTHON_BIN - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    payload = json.load(f)
print('true' if payload.get('ok') else 'false')
PY
)"

echo "prove_mapping_integrity_report=${REPORT_FILE}"
echo "prove_mapping_integrity_latest=${LATEST_FILE}"
echo "prove_mapping_integrity_ok=${PROOF_OK}"

if [[ "$PROOF_OK" != "true" ]]; then
  exit 1
fi
