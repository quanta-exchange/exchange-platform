#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LOAD_ORDERS="${LOAD_10K_ORDERS:-10000}" \
LOAD_CONCURRENCY="${LOAD_10K_CONCURRENCY:-64}" \
LOAD_WS_CLIENTS="${LOAD_10K_WS_CLIENTS:-500}" \
LOAD_TRADES="${LOAD_10K_TRADES:-4000}" \
LOAD_WS_DURATION_SEC="${LOAD_10K_WS_DURATION_SEC:-12}" \
LOAD_THRESHOLDS_FILE="${LOAD_10K_THRESHOLDS_FILE:-infra/load/thresholds-10k.json}" \
LOAD_OUT_FILE="${LOAD_10K_OUT_FILE:-build/load/load-10k.json}" \
LOAD_CHECK="${LOAD_10K_CHECK:-true}" \
"$ROOT_DIR/scripts/load_smoke.sh"

echo "load_10k_success=true"
echo "load_10k_report=${LOAD_10K_OUT_FILE:-build/load/load-10k.json}"
