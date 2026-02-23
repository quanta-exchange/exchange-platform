#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EDGE_LOG="/tmp/edge-gateway-load.log"
EDGE_PORT="${EDGE_PORT:-18081}"
LOAD_ORDERS="${LOAD_ORDERS:-120}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-12}"
LOAD_WS_CLIENTS="${LOAD_WS_CLIENTS:-10}"
LOAD_TRADES="${LOAD_TRADES:-80}"
LOAD_WS_DURATION_SEC="${LOAD_WS_DURATION_SEC:-3}"
LOAD_THRESHOLDS_FILE="${LOAD_THRESHOLDS_FILE:-infra/load/thresholds-smoke.json}"
LOAD_OUT_FILE="${LOAD_OUT_FILE:-build/load/load-smoke.json}"
LOAD_CHECK="${LOAD_CHECK:-true}"

cleanup() {
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "$EDGE_PID" 2>/dev/null; then
    kill "$EDGE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

EDGE_ADDR=":${EDGE_PORT}" \
EDGE_DISABLE_DB="true" \
EDGE_DISABLE_CORE="${EDGE_DISABLE_CORE:-false}" \
EDGE_ENABLE_SMOKE_ROUTES="${EDGE_ENABLE_SMOKE_ROUTES:-true}" \
EDGE_ALLOW_INSECURE_NO_AUTH="true" \
go run ./services/edge-gateway/cmd/edge-gateway >"$EDGE_LOG" 2>&1 &
EDGE_PID=$!

for _ in {1..120}; do
  if curl -fsS "http://localhost:${EDGE_PORT}/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://localhost:${EDGE_PORT}/readyz" >/dev/null 2>&1; then
  echo "edge-gateway readiness failed for load smoke"
  cat "$EDGE_LOG"
  exit 1
fi

if [[ "${LOAD_CHECK}" == "true" ]]; then
  go run ./scripts/load-harness \
    -target "http://localhost:${EDGE_PORT}" \
    -orders "${LOAD_ORDERS}" \
    -concurrency "${LOAD_CONCURRENCY}" \
    -ws-clients "${LOAD_WS_CLIENTS}" \
    -trades "${LOAD_TRADES}" \
    -ws-duration-sec "${LOAD_WS_DURATION_SEC}" \
    -thresholds "${LOAD_THRESHOLDS_FILE}" \
    -check \
    -out "${LOAD_OUT_FILE}"
else
  go run ./scripts/load-harness \
    -target "http://localhost:${EDGE_PORT}" \
    -orders "${LOAD_ORDERS}" \
    -concurrency "${LOAD_CONCURRENCY}" \
    -ws-clients "${LOAD_WS_CLIENTS}" \
    -trades "${LOAD_TRADES}" \
    -ws-duration-sec "${LOAD_WS_DURATION_SEC}" \
    -thresholds "${LOAD_THRESHOLDS_FILE}" \
    -out "${LOAD_OUT_FILE}"
fi

echo "load_smoke_success=true"
echo "load_smoke_report=${LOAD_OUT_FILE}"
