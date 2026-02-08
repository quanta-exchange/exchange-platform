#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <user> <ticket_id> <reason> <duration_minutes>"
  exit 1
fi

USER_NAME="$1"
TICKET_ID="$2"
REASON="$3"
DURATION_MIN="$4"

EXPIRES_AT="$(date -u -v+"${DURATION_MIN}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+${DURATION_MIN} minutes" +"%Y-%m-%dT%H:%M:%SZ")"
BINDING_NAME="jit-ops-admin-${USER_NAME//[^a-zA-Z0-9-]/-}-$(date +%s)"

cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${BINDING_NAME}
  annotations:
    exchange.quanta.io/ticket-id: "${TICKET_ID}"
    exchange.quanta.io/reason: "${REASON}"
    exchange.quanta.io/expires-at: "${EXPIRES_AT}"
subjects:
  - kind: User
    name: ${USER_NAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: exchange-ops-admin
YAML
