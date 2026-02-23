#!/usr/bin/env bash
# shellcheck shell=bash

audit_chain_append() {
  local audit_file="$1"
  local event="$2"
  local actor="$3"
  local reason="$4"
  local payload_json="$5"
  local ts prev_hash last_line base_json row_hash final_json

  mkdir -p "$(dirname "$audit_file")"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  prev_hash="GENESIS"

  if [[ -f "$audit_file" && -s "$audit_file" ]]; then
    last_line="$(tail -n 1 "$audit_file" || true)"
    prev_hash="$(
      python3 - "$last_line" <<'PY'
import json
import sys

line = sys.argv[1].strip()
if not line:
    print("GENESIS")
    raise SystemExit(0)
try:
    row = json.loads(line)
except Exception:
    print("LEGACY")
    raise SystemExit(0)
print(row.get("hash") or "LEGACY")
PY
    )"
  fi

  base_json="$(
    python3 - "$ts" "$event" "$actor" "$reason" "$payload_json" "$prev_hash" <<'PY'
import json
import sys

ts, event, actor, reason, payload_raw, prev_hash = sys.argv[1:7]
payload = json.loads(payload_raw)
row = {
    "ts": ts,
    "event": event,
    "actor": actor,
    "reason": reason,
    "payload": payload,
    "prevHash": prev_hash,
}
print(json.dumps(row, separators=(",", ":"), sort_keys=True))
PY
  )"

  row_hash="$(printf '%s' "$base_json" | shasum -a 256 | awk '{print $1}')"
  final_json="$(
    python3 - "$base_json" "$row_hash" <<'PY'
import json
import sys

row = json.loads(sys.argv[1])
row["hash"] = sys.argv[2]
print(json.dumps(row, separators=(",", ":"), sort_keys=True))
PY
  )"
  echo "$final_json" >>"$audit_file"
}
