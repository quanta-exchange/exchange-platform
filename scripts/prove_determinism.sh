#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/determinism}"
RUNS="${RUNS:-5}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      RUNS="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
  echo "RUNS must be positive integer" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/$TS_ID"
LOG_DIR="$RUN_DIR/logs"
REPORT_FILE="$RUN_DIR/prove-determinism.json"
mkdir -p "$LOG_DIR"

RESULTS_FILE="$RUN_DIR/results.tsv"
: >"$RESULTS_FILE"

for i in $(seq 1 "$RUNS"); do
  LOG_FILE="$LOG_DIR/run-${i}.log"
  echo "determinism_run=${i}/${RUNS}"
  set +e
  N_INITIAL_ORDERS=4 \
  N_AFTER_CORE_RESTART=2 \
  CHAOS_SKIP_LEDGER_ASSERTS=true \
  "$ROOT_DIR/scripts/chaos/core_kill_recover.sh" >"$LOG_FILE" 2>&1
  CODE=$?
  set -e

  STATUS="fail"
  HASH=""
  SEQ=""
  if [[ "$CODE" -eq 0 ]]; then
    STATUS="pass"
    HASH="$(grep -E '^core_recovery_hash=' "$LOG_FILE" | tail -n 1 | sed 's/^core_recovery_hash=//')"
    SEQ="$(grep -E '^core_recovery_seq=' "$LOG_FILE" | tail -n 1 | sed 's/^core_recovery_seq=//')"
    if [[ -z "$HASH" || -z "$SEQ" ]]; then
      STATUS="fail"
      CODE=2
    fi
  fi

  echo -e "${i}\t${STATUS}\t${HASH}\t${SEQ}\t${CODE}\t${LOG_FILE}" >>"$RESULTS_FILE"
  if [[ "$STATUS" != "pass" ]]; then
    echo "determinism_run_failed=${i}" >&2
    break
  fi
done

"$PYTHON_BIN" - "$RESULTS_FILE" "$REPORT_FILE" "$RUNS" <<'PY'
import json
import sys
from datetime import datetime, timezone

rows = []
all_pass = True
reference_hash = None
reference_seq = None
distinct_hashes = set()
distinct_seqs = set()
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        run_idx, status, h, seq, code, log = raw.split("\t")
        row = {
            "run": int(run_idx),
            "status": status,
            "coreRecoveryHash": h or None,
            "coreRecoverySeq": int(seq) if seq.isdigit() else None,
            "exitCode": int(code),
            "log": log,
        }
        if status != "pass":
            all_pass = False
        else:
            if reference_hash is None:
                reference_hash = h
            if reference_seq is None:
                reference_seq = int(seq)
            if h != reference_hash:
                all_pass = False
            if int(seq) != reference_seq:
                all_pass = False
            distinct_hashes.add(h)
            distinct_seqs.add(int(seq))
        rows.append(row)

requested_runs = int(sys.argv[3])
if len(rows) < requested_runs:
    all_pass = False

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": all_pass,
    "requested_runs": requested_runs,
    "executed_runs": len(rows),
    "reference_hash": reference_hash,
    "reference_seq": reference_seq,
    "distinct_hashes": sorted(distinct_hashes),
    "distinct_seqs": sorted(distinct_seqs),
    "results": rows,
}

with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$OUT_DIR/prove-determinism-latest.json"

OK="$("$PYTHON_BIN" - <<'PY' "$REPORT_FILE"
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "prove_determinism_report=$REPORT_FILE"
echo "prove_determinism_ok=$OK"

if [[ "$OK" != "true" ]]; then
  exit 1
fi
