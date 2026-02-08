#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl_not_found=true"
  echo "k8s_policy_smoke=skipped"
  exit 0
fi

if ! kubectl version --request-timeout=2s >/dev/null 2>&1; then
  echo "kubectl_cluster_unreachable=true"
  echo "k8s_policy_smoke=skipped"
  exit 0
fi

kubectl apply --dry-run=client --validate=false -k "$ROOT_DIR/infra/k8s/overlays/dev" >/dev/null
kubectl apply --dry-run=client --validate=false -k "$ROOT_DIR/infra/k8s/overlays/staging" >/dev/null
kubectl apply --dry-run=client --validate=false -k "$ROOT_DIR/infra/k8s/overlays/prod" >/dev/null

echo "k8s_policy_smoke=ok"
