#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EDGE_LOG="/tmp/edge-gateway-load.log"

cleanup() {
  if [[ -n "${EDGE_PID:-}" ]] && kill -0 "$EDGE_PID" 2>/dev/null; then
    kill "$EDGE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

EDGE_ADDR=":18081" EDGE_DISABLE_DB="true" go run ./services/edge-gateway/cmd/edge-gateway >"$EDGE_LOG" 2>&1 &
EDGE_PID=$!

for _ in {1..120}; do
  if curl -fsS "http://localhost:18081/readyz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS "http://localhost:18081/readyz" >/dev/null 2>&1; then
  echo "edge-gateway readiness failed for load smoke"
  cat "$EDGE_LOG"
  exit 1
fi

go run ./scripts/load-harness \
  -target "http://localhost:18081" \
  -orders 120 \
  -concurrency 12 \
  -ws-clients 10 \
  -trades 80 \
  -ws-duration-sec 3 \
  -thresholds "infra/load/thresholds-smoke.json" \
  -check \
  -out "build/load/load-smoke.json"

echo "load_smoke_success=true"
