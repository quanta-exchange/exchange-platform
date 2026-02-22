#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CHAOS_KILL_CORE=false \
CHAOS_KILL_LEDGER=true \
N_INITIAL_ORDERS="${N_INITIAL_ORDERS:-8}" \
N_AFTER_CORE_RESTART=0 \
N_WHILE_LEDGER_DOWN="${N_WHILE_LEDGER_DOWN:-5}" \
N_AFTER_LEDGER_RESTART="${N_AFTER_LEDGER_RESTART:-3}" \
  "${ROOT_DIR}/scripts/chaos_replay.sh"

