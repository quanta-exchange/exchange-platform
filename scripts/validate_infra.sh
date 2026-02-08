#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

has_pattern() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
    return
  fi
  grep -q "$pattern" "$file"
}

required_files=(
  "infra/k8s/base/namespaces.yaml"
  "infra/k8s/base/networkpolicies.yaml"
  "infra/k8s/base/rbac.yaml"
  "infra/gitops/argocd/project-exchange.yaml"
  "infra/gitops/argocd/root-app.yaml"
  "infra/gitops/apps/dev.yaml"
  "infra/gitops/apps/staging.yaml"
  "infra/gitops/apps/prod.yaml"
)

for f in "${required_files[@]}"; do
  if [[ ! -f "$ROOT_DIR/$f" ]]; then
    echo "missing file: $f"
    exit 1
  fi
done

if ! has_pattern "name: core" "$ROOT_DIR/infra/k8s/base/namespaces.yaml"; then
  echo "missing core namespace"
  exit 1
fi
if ! has_pattern "name: default-deny" "$ROOT_DIR/infra/k8s/base/networkpolicies.yaml"; then
  echo "missing default-deny network policies"
  exit 1
fi
if ! has_pattern "exchange-ops-admin" "$ROOT_DIR/infra/k8s/base/rbac.yaml"; then
  echo "missing ops admin role"
  exit 1
fi
if ! has_pattern "name: exchange-platform-root" "$ROOT_DIR/infra/gitops/argocd/root-app.yaml"; then
  echo "missing root app"
  exit 1
fi

if command -v kubectl >/dev/null 2>&1; then
  "$ROOT_DIR/scripts/k8s_policy_smoke.sh"
  "$ROOT_DIR/scripts/gitops_dry_run.sh"
fi

echo "infra_validation_success=true"
