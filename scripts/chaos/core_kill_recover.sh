#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CHAOS_KILL_CORE=true \
CHAOS_KILL_LEDGER=false \
CHAOS_SKIP_LEDGER_ASSERTS="${CHAOS_SKIP_LEDGER_ASSERTS:-true}" \
N_INITIAL_ORDERS="${N_INITIAL_ORDERS:-4}" \
N_AFTER_CORE_RESTART="${N_AFTER_CORE_RESTART:-2}" \
N_WHILE_LEDGER_DOWN=0 \
N_AFTER_LEDGER_RESTART=0 \
  "${ROOT_DIR}/scripts/chaos_replay.sh"
