#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/infra/compose/docker-compose.yml"
TOPIC="${TOPIC:-chaos.redpanda.bounce.v1}"

docker compose -f "${COMPOSE_FILE}" up -d redpanda redpanda-init

echo "[chaos:redpanda] wait cluster ready"
for _ in {1..90}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null

echo "[chaos:redpanda] create topic and publish baseline"
docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic create "${TOPIC}" -p 3 -r 1 >/dev/null 2>&1 || true
printf '{"msg":"before-bounce"}\n' | docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic produce "${TOPIC}" >/dev/null

echo "[chaos:redpanda] stop broker"
docker compose -f "${COMPOSE_FILE}" stop redpanda >/dev/null
sleep 3

if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
  echo "expected broker to be unavailable after stop" >&2
  exit 1
fi

echo "[chaos:redpanda] restart broker"
docker compose -f "${COMPOSE_FILE}" start redpanda >/dev/null

for _ in {1..90}; do
  if docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk cluster info >/dev/null

echo "[chaos:redpanda] publish and consume after restart"
printf '{"msg":"after-bounce"}\n' | docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic produce "${TOPIC}" >/dev/null
CONSUMED="$(docker compose -f "${COMPOSE_FILE}" exec -T redpanda rpk topic consume "${TOPIC}" -n 1 -o -1 -f '%v\n' || true)"

if ! grep -q '"after-bounce"' <<<"${CONSUMED}"; then
  echo "did not observe post-bounce message on consume output" >&2
  echo "${CONSUMED}" >&2
  exit 1
fi

echo "redpanda_broker_bounce_success=true"
