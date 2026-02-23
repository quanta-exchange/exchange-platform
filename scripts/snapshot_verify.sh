#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/snapshot}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SNAPSHOT_FILE="${SNAPSHOT_FILE:-}"
SNAPSHOT_URI="${SNAPSHOT_URI:-}"
SNAPSHOT_SHA256_FILE="${SNAPSHOT_SHA256_FILE:-}"
CORE_WAL_DIR="${CORE_WAL_DIR:-/tmp/trading-core/wal}"
CORE_OUTBOX_DIR="${CORE_OUTBOX_DIR:-/tmp/trading-core/outbox}"
CORE_SYMBOL="${CORE_SYMBOL:-BTC-KRW}"
CREATE_IF_MISSING="${CREATE_IF_MISSING:-true}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --snapshot-file)
      SNAPSHOT_FILE="$2"
      shift 2
      ;;
    --snapshot-uri)
      SNAPSHOT_URI="$2"
      shift 2
      ;;
    --sha256-file)
      SNAPSHOT_SHA256_FILE="$2"
      shift 2
      ;;
    --wal-dir)
      CORE_WAL_DIR="$2"
      shift 2
      ;;
    --outbox-dir)
      CORE_OUTBOX_DIR="$2"
      shift 2
      ;;
    --symbol)
      CORE_SYMBOL="$2"
      shift 2
      ;;
    --create-if-missing)
      CREATE_IF_MISSING="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
LOG_FILE="$OUT_DIR/snapshot-verify-$TS_ID.log"
REPORT_FILE="$OUT_DIR/snapshot-verify-$TS_ID.json"
LATEST_FILE="$OUT_DIR/snapshot-verify-latest.json"

sha256_of_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return
  fi
  shasum -a 256 "$file" | awk '{print $1}'
}

ensure_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd. $hint" >&2
    exit 1
  fi
}

ensure_cmd cargo "Install Rust toolchain."
ensure_cmd "$PYTHON_BIN" "Install Python 3."

if [[ "$(uname -s)" == "Darwin" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  export SDKROOT
  export CFLAGS="-isysroot ${SDKROOT} ${CFLAGS:-}"
  export CXXFLAGS="-isysroot ${SDKROOT} -I${SDKROOT}/usr/include/c++/v1 ${CXXFLAGS:-}"
fi

LOCAL_SNAPSHOT=""
SNAPSHOT_SOURCE="generated"

if [[ -n "$SNAPSHOT_URI" ]]; then
  LOCAL_SNAPSHOT="$OUT_DIR/snapshot-from-uri-$TS_ID.json"
  SNAPSHOT_SOURCE="$SNAPSHOT_URI"
  case "$SNAPSHOT_URI" in
    http://*|https://*)
      ensure_cmd curl "Install curl for remote snapshot download."
      curl -fsSL "$SNAPSHOT_URI" -o "$LOCAL_SNAPSHOT"
      ;;
    file://*)
      cp "${SNAPSHOT_URI#file://}" "$LOCAL_SNAPSHOT"
      ;;
    *)
      if [[ -f "$SNAPSHOT_URI" ]]; then
        cp "$SNAPSHOT_URI" "$LOCAL_SNAPSHOT"
      else
        echo "unsupported snapshot uri or file missing: $SNAPSHOT_URI" >&2
        exit 1
      fi
      ;;
  esac
elif [[ -n "$SNAPSHOT_FILE" ]]; then
  LOCAL_SNAPSHOT="$SNAPSHOT_FILE"
  SNAPSHOT_SOURCE="$SNAPSHOT_FILE"
fi

if [[ -z "$LOCAL_SNAPSHOT" ]]; then
  LOCAL_SNAPSHOT="$OUT_DIR/snapshot-generated-$TS_ID.json"
fi

if [[ ! -f "$LOCAL_SNAPSHOT" ]]; then
  if [[ "$CREATE_IF_MISSING" == "true" ]]; then
    (
      cd "$ROOT_DIR"
      cargo run -q -p trading-core --bin snapshot-tool -- create \
        --snapshot "$LOCAL_SNAPSHOT" \
        --symbol "$CORE_SYMBOL" \
        --wal-dir "$CORE_WAL_DIR" \
        --outbox-dir "$CORE_OUTBOX_DIR" >"$LOG_FILE" 2>&1
    )
  else
    echo "snapshot file missing and create-if-missing=false: $LOCAL_SNAPSHOT" >&2
    exit 1
  fi
fi

SHA_STATUS="skipped"
SHA_EXPECTED=""
SHA_ACTUAL=""

if [[ -n "$SNAPSHOT_SHA256_FILE" || -f "${LOCAL_SNAPSHOT}.sha256" ]]; then
  SHA_SOURCE="$SNAPSHOT_SHA256_FILE"
  if [[ -z "$SHA_SOURCE" ]]; then
    SHA_SOURCE="${LOCAL_SNAPSHOT}.sha256"
  fi
  if [[ ! -f "$SHA_SOURCE" ]]; then
    echo "sha256 file not found: $SHA_SOURCE" >&2
    exit 1
  fi
  SHA_EXPECTED="$(awk '{print $1}' "$SHA_SOURCE" | head -n 1)"
  SHA_ACTUAL="$(sha256_of_file "$LOCAL_SNAPSHOT")"
  if [[ "$SHA_EXPECTED" != "$SHA_ACTUAL" ]]; then
    SHA_STATUS="mismatch"
    echo "snapshot checksum mismatch expected=$SHA_EXPECTED actual=$SHA_ACTUAL" >&2
    exit 1
  fi
  SHA_STATUS="verified"
fi

(
  cd "$ROOT_DIR"
  cargo run -q -p trading-core --bin snapshot-tool -- verify \
    --snapshot "$LOCAL_SNAPSHOT" \
    --symbol "$CORE_SYMBOL" \
    --wal-dir "$CORE_WAL_DIR" \
    --outbox-dir "$CORE_OUTBOX_DIR" >>"$LOG_FILE" 2>&1
)

VERIFY_OK="$(
  grep -E '^snapshot_tool_ok=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"
BASELINE_SEQ="$(
  grep -E '^snapshot_tool_baseline_seq=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"
BASELINE_HASH="$(
  grep -E '^snapshot_tool_baseline_hash=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"
REHEARSAL_SEQ="$(
  grep -E '^snapshot_tool_rehearsal_seq=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"
REHEARSAL_HASH="$(
  grep -E '^snapshot_tool_rehearsal_hash=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"
SNAPSHOT_SEQ="$(
  grep -E '^snapshot_tool_snapshot_seq=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"
SNAPSHOT_HASH="$(
  grep -E '^snapshot_tool_snapshot_hash=' "$LOG_FILE" | tail -n 1 | cut -d= -f2
)"

if [[ -z "$VERIFY_OK" ]]; then
  echo "snapshot verification output missing in log: $LOG_FILE" >&2
  exit 1
fi

REPORT_FILE="$REPORT_FILE" \
TS_ID="$TS_ID" \
SNAPSHOT_SOURCE="$SNAPSHOT_SOURCE" \
LOCAL_SNAPSHOT="$LOCAL_SNAPSHOT" \
SHA_STATUS="$SHA_STATUS" \
SHA_EXPECTED="$SHA_EXPECTED" \
SHA_ACTUAL="$SHA_ACTUAL" \
VERIFY_OK="$VERIFY_OK" \
BASELINE_SEQ="$BASELINE_SEQ" \
BASELINE_HASH="$BASELINE_HASH" \
REHEARSAL_SEQ="$REHEARSAL_SEQ" \
REHEARSAL_HASH="$REHEARSAL_HASH" \
SNAPSHOT_SEQ="$SNAPSHOT_SEQ" \
SNAPSHOT_HASH="$SNAPSHOT_HASH" \
CORE_WAL_DIR="$CORE_WAL_DIR" \
CORE_OUTBOX_DIR="$CORE_OUTBOX_DIR" \
CORE_SYMBOL="$CORE_SYMBOL" \
LOG_FILE="$LOG_FILE" \
"$PYTHON_BIN" - <<'PY'
import json
import os
from datetime import datetime, timezone

def parse_int(v: str):
    try:
        return int(v)
    except Exception:
        return None

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": os.environ["TS_ID"],
    "ok": os.environ["VERIFY_OK"].lower() == "true",
    "snapshot": {
        "source": os.environ["SNAPSHOT_SOURCE"],
        "path": os.environ["LOCAL_SNAPSHOT"],
        "sha256_status": os.environ["SHA_STATUS"],
        "sha256_expected": os.environ["SHA_EXPECTED"] or None,
        "sha256_actual": os.environ["SHA_ACTUAL"] or None,
        "snapshot_seq": parse_int(os.environ["SNAPSHOT_SEQ"]),
        "snapshot_hash": os.environ["SNAPSHOT_HASH"] or None,
    },
    "rehearsal": {
        "symbol": os.environ["CORE_SYMBOL"],
        "wal_dir": os.environ["CORE_WAL_DIR"],
        "outbox_dir": os.environ["CORE_OUTBOX_DIR"],
        "baseline_seq": parse_int(os.environ["BASELINE_SEQ"]),
        "baseline_hash": os.environ["BASELINE_HASH"] or None,
        "rehearsal_seq": parse_int(os.environ["REHEARSAL_SEQ"]),
        "rehearsal_hash": os.environ["REHEARSAL_HASH"] or None,
    },
    "log": os.environ["LOG_FILE"],
}

with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "snapshot_verify_report=$REPORT_FILE"
echo "snapshot_verify_latest=$LATEST_FILE"
echo "snapshot_verify_ok=$VERIFY_OK"
