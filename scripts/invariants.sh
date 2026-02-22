#!/usr/bin/env bash
set -euo pipefail

LEDGER_BASE_URL="${LEDGER_BASE_URL:-http://localhost:8082}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"
OUT_DIR="${OUT_DIR:-build/invariants}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "${OUT_DIR}"

ADMIN_HEADERS=()
if [[ -n "${LEDGER_ADMIN_TOKEN}" ]]; then
  ADMIN_HEADERS=(-H "X-Admin-Token: ${LEDGER_ADMIN_TOKEN}")
fi

LEDGER_RESULT="$(curl -fsS "${ADMIN_HEADERS[@]}" -X POST "${LEDGER_BASE_URL}/v1/admin/invariants/check")"
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
