#!/usr/bin/env bash
set -euo pipefail

MANIFEST="${MANIFEST:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      MANIFEST="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$MANIFEST" ]]; then
  echo "missing --manifest" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 1
fi

IFS=$'\t' read -r EVENT_FILE EXPECTED_SHA <<<"$(python3 - <<'PY' "$MANIFEST"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(f"{payload.get('event_file', '')}\t{payload.get('event_sha256', '')}")
PY
)"

if [[ ! -f "$EVENT_FILE" ]]; then
  echo "event file not found: $EVENT_FILE" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "$EVENT_FILE" | awk '{print $1}')"
else
  ACTUAL_SHA="$(shasum -a 256 "$EVENT_FILE" | awk '{print $1}')"
fi

if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "archive checksum mismatch: expected=$EXPECTED_SHA actual=$ACTUAL_SHA" >&2
  exit 1
fi

echo "verify_archive_ok=true"
echo "verify_archive_manifest=$MANIFEST"
echo "verify_archive_sha256=$ACTUAL_SHA"
