#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/break-glass}"
STATE_FILE="$OUT_DIR/state.json"
AUDIT_FILE="$OUT_DIR/audit.log"

ACTION="${1:-status}"
shift || true

TTL_SECONDS="${TTL_SECONDS:-900}"
ACTOR="${ACTOR:-unknown}"
REASON="${REASON:-unspecified}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ttl-sec)
      TTL_SECONDS="$2"
      shift 2
      ;;
    --actor)
      ACTOR="$2"
      shift 2
      ;;
    --reason)
      REASON="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"

now_epoch() {
  date -u +%s
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

write_audit() {
  local event="$1"
  local payload="$2"
  echo "{\"ts\":\"$(now_iso)\",\"event\":\"${event}\",\"actor\":\"${ACTOR}\",\"reason\":\"${REASON}\",\"payload\":${payload}}" >>"$AUDIT_FILE"
}

status_json() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"enabled":false}'
    return
  fi
  cat "$STATE_FILE"
}

case "$ACTION" in
  enable)
    if ! [[ "$TTL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TTL_SECONDS" -lt 1 ]]; then
      echo "ttl must be positive integer seconds" >&2
      exit 1
    fi
    START_EPOCH="$(now_epoch)"
    EXPIRES_EPOCH="$((START_EPOCH + TTL_SECONDS))"
    cat >"$STATE_FILE" <<JSON
{
  "enabled": true,
  "enabledAtUtc": "$(now_iso)",
  "enabledBy": "${ACTOR}",
  "reason": "${REASON}",
  "ttlSeconds": ${TTL_SECONDS},
  "expiresAtEpoch": ${EXPIRES_EPOCH}
}
JSON
    write_audit "enable" "{\"ttlSeconds\":${TTL_SECONDS},\"expiresAtEpoch\":${EXPIRES_EPOCH}}"
    echo "break_glass_enabled=true"
    echo "break_glass_state=$STATE_FILE"
    ;;
  disable)
    if [[ -f "$STATE_FILE" ]]; then
      rm "$STATE_FILE"
    fi
    write_audit "disable" "{}"
    echo "break_glass_enabled=false"
    ;;
  status)
    STATUS_RAW="$(status_json)"
    EXPIRES_EPOCH="$(
      python3 - <<'PY' "$STATUS_RAW"
import json, sys
payload = json.loads(sys.argv[1])
print(payload.get("expiresAtEpoch", 0))
PY
    )"
    ENABLED="$(
      python3 - <<'PY' "$STATUS_RAW"
import json, sys
payload = json.loads(sys.argv[1])
print("true" if payload.get("enabled", False) else "false")
PY
    )"
    NOW="$(now_epoch)"
    if [[ "$ENABLED" == "true" && "$EXPIRES_EPOCH" -gt 0 && "$NOW" -ge "$EXPIRES_EPOCH" ]]; then
      rm -f "$STATE_FILE"
      write_audit "auto_expire" "{\"expiredAtEpoch\":${NOW}}"
      echo "break_glass_enabled=false"
      echo "break_glass_expired=true"
      exit 0
    fi
    echo "break_glass_status=${STATUS_RAW}"
    ;;
  *)
    echo "usage: $0 [enable|disable|status] [--ttl-sec N] [--actor name] [--reason text]" >&2
    exit 1
    ;;
esac
