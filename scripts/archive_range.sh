#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/archive}"
BROKERS="${BROKERS:-localhost:29092}"
TOPIC="${TOPIC:-}"
FROM_OFFSET="${FROM_OFFSET:-start}"
COUNT="${COUNT:-1000}"
SOURCE_FILE="${SOURCE_FILE:-}"
RPK_BIN="${RPK_BIN:-rpk}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic)
      TOPIC="$2"
      shift 2
      ;;
    --from)
      FROM_OFFSET="$2"
      shift 2
      ;;
    --count)
      COUNT="$2"
      shift 2
      ;;
    --brokers)
      BROKERS="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --source-file)
      SOURCE_FILE="$2"
      shift 2
      ;;
    --rpk-bin)
      RPK_BIN="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_FILE" && -z "$TOPIC" ]]; then
  echo "either --topic or --source-file must be provided" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/$TS_ID"
mkdir -p "$RUN_DIR"

EVENT_FILE="$RUN_DIR/events.jsonl"
MANIFEST_FILE="$RUN_DIR/manifest.json"
SHA_FILE="$RUN_DIR/events.sha256"

if [[ -n "$SOURCE_FILE" ]]; then
  if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "source file not found: $SOURCE_FILE" >&2
    exit 1
  fi
  cp "$SOURCE_FILE" "$EVENT_FILE"
else
  "$RPK_BIN" topic consume "$TOPIC" -X brokers="$BROKERS" -o "$FROM_OFFSET" -n "$COUNT" -f '%v\n' >"$EVENT_FILE"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$EVENT_FILE" | awk '{print $1}' >"$SHA_FILE"
else
  shasum -a 256 "$EVENT_FILE" | awk '{print $1}' >"$SHA_FILE"
fi

EVENT_SHA="$(cat "$SHA_FILE")"
EVENT_LINES="$(wc -l <"$EVENT_FILE" | tr -d '[:space:]')"

python3 - "$MANIFEST_FILE" "$TOPIC" "$FROM_OFFSET" "$COUNT" "$BROKERS" "$SOURCE_FILE" "$EVENT_FILE" "$EVENT_SHA" "$EVENT_LINES" <<'PY'
import json
import sys
from datetime import datetime, timezone

manifest_file = sys.argv[1]
topic = sys.argv[2]
from_offset = sys.argv[3]
count = sys.argv[4]
brokers = sys.argv[5]
source_file = sys.argv[6]
event_file = sys.argv[7]
event_sha = sys.argv[8]
event_lines = int(sys.argv[9])

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "topic": topic or None,
    "from_offset": from_offset,
    "count_requested": int(count),
    "brokers": brokers if topic else None,
    "source_file": source_file or None,
    "event_file": event_file,
    "event_sha256": event_sha,
    "event_lines": event_lines,
}

with open(manifest_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "archive_range_ok=true"
echo "archive_run_dir=$RUN_DIR"
echo "archive_manifest=$MANIFEST_FILE"
echo "archive_events=$EVENT_FILE"
echo "archive_events_sha256=$EVENT_SHA"
