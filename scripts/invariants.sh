#!/usr/bin/env bash
set -euo pipefail

LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
OUT_DIR="${OUT_DIR:-build/invariants}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${OUT_DIR}"

LEDGER_RESULT="$(curl -fsS -X POST "${LEDGER_BASE_URL}/v1/admin/invariants/check")"
LEDGER_FILE="${OUT_DIR}/ledger-invariants.json"
echo "${LEDGER_RESULT}" > "${LEDGER_FILE}"

export LEDGER_FILE

"${PYTHON_BIN}" - <<'PY'
import json
import os
import sys

with open(os.environ["LEDGER_FILE"], "r", encoding="utf-8") as f:
    payload = json.load(f)
if bool(payload.get("ok", False)):
    print("invariants_success=true")
    sys.exit(0)

print(f"invariants_success=false violations={payload.get('violations', [])}", file=sys.stderr)
sys.exit(1)
PY
