#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl_not_found=true"
  echo "gitops_dry_run=skipped"
  exit 0
fi

if ! kubectl version --request-timeout=2s >/dev/null 2>&1; then
  echo "kubectl_cluster_unreachable=true"
  echo "gitops_dry_run=skipped"
  exit 0
fi

kubectl apply --dry-run=client --validate=false -f "$ROOT_DIR/infra/gitops/argocd/project-exchange.yaml" >/dev/null
kubectl apply --dry-run=client --validate=false -f "$ROOT_DIR/infra/gitops/argocd/root-app.yaml" >/dev/null
kubectl apply --dry-run=client --validate=false -f "$ROOT_DIR/infra/gitops/apps/dev.yaml" >/dev/null
kubectl apply --dry-run=client --validate=false -f "$ROOT_DIR/infra/gitops/apps/staging.yaml" >/dev/null
kubectl apply --dry-run=client --validate=false -f "$ROOT_DIR/infra/gitops/apps/prod.yaml" >/dev/null

echo "gitops_dry_run=ok"
