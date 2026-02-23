#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LOAD_ORDERS="${LOAD_50K_ORDERS:-50000}" \
LOAD_CONCURRENCY="${LOAD_50K_CONCURRENCY:-128}" \
LOAD_WS_CLIENTS="${LOAD_50K_WS_CLIENTS:-2000}" \
LOAD_TRADES="${LOAD_50K_TRADES:-20000}" \
LOAD_WS_DURATION_SEC="${LOAD_50K_WS_DURATION_SEC:-20}" \
LOAD_THRESHOLDS_FILE="${LOAD_50K_THRESHOLDS_FILE:-infra/load/thresholds-50k.json}" \
LOAD_OUT_FILE="${LOAD_50K_OUT_FILE:-build/load/load-50k.json}" \
LOAD_CHECK="${LOAD_50K_CHECK:-true}" \
"$ROOT_DIR/scripts/load_smoke.sh"

echo "load_50k_success=true"
echo "load_50k_report=${LOAD_50K_OUT_FILE:-build/load/load-50k.json}"
