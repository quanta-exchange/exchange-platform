#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCAN_ROOTS="${SCAN_ROOTS:-$ROOT_DIR/build/runbooks,$ROOT_DIR/build/release-gate,$ROOT_DIR/build/verification,$ROOT_DIR/build/status,$ROOT_DIR/build/safety-case,$ROOT_DIR/build/compliance,$ROOT_DIR/build/transparency,$ROOT_DIR/build/audit,$ROOT_DIR/build/controls,$ROOT_DIR/build/security}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/security}"
MAX_HITS="${MAX_HITS:-200}"
ALLOW_MISSING=true
ALLOW_HITS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scan-root)
      SCAN_ROOTS="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --max-hits)
      MAX_HITS="$2"
      shift 2
      ;;
    --allow-missing)
      ALLOW_MISSING=true
      shift
      ;;
    --allow-hits)
      ALLOW_HITS=true
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/pii-log-scan-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/pii-log-scan-latest.json"

python3 - "$SCAN_ROOTS" "$REPORT_FILE" "$MAX_HITS" "$ALLOW_MISSING" <<'PY'
import json
import pathlib
import re
import sys
from datetime import datetime, timezone

scan_roots = [pathlib.Path(part.strip()).resolve() for part in sys.argv[1].split(",") if part.strip()]
report_file = pathlib.Path(sys.argv[2]).resolve()
max_hits = int(sys.argv[3])
allow_missing = sys.argv[4].lower() == "true"

email_re = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
ssn_re = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")
phone_re = re.compile(r"(?<!\d)(?:\+?\d[\d\-\(\) ]{8,}\d)(?!\d)")
phone_label_re = re.compile(r"(?i)\b(phone|mobile|tel)\b")

allowed_suffixes = {
    ".log",
    ".txt",
    ".json",
    ".ndjson",
    ".csv",
    ".md",
}

hits = []
files_scanned = 0
missing_roots = [str(root) for root in scan_roots if not root.exists()]

for root in scan_roots:
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() not in allowed_suffixes:
            continue
        files_scanned += 1
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except Exception:
            continue
        for idx, line in enumerate(lines, 1):
            line_hits = []
            if email_re.search(line):
                line_hits.append("email")
            if ssn_re.search(line):
                line_hits.append("ssn")
            if phone_label_re.search(line) and phone_re.search(line):
                line_hits.append("phone")
            if not line_hits:
                continue
            snippet = line.strip()
            if len(snippet) > 180:
                snippet = snippet[:180] + "..."
            for kind in line_hits:
                hits.append(
                    {
                        "type": kind,
                        "file": str(path),
                        "line": idx,
                        "snippet": snippet,
                    }
                )
                if len(hits) >= max_hits:
                    break
            if len(hits) >= max_hits:
                break
        if len(hits) >= max_hits:
            break

ok = True
errors = []
if missing_roots and not allow_missing:
    ok = False
    errors.append(f"scan roots missing: {', '.join(missing_roots)}")
if hits:
    ok = False

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "scan_roots": [str(root) for root in scan_roots],
    "scan_roots_missing": missing_roots,
    "files_scanned": files_scanned,
    "hit_count": len(hits),
    "max_hits": max_hits,
    "ok": ok,
    "errors": errors,
    "hits": hits,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

SCAN_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

HIT_COUNT="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("hit_count", 0)))
PY
)"

echo "pii_log_scan_report=$REPORT_FILE"
echo "pii_log_scan_latest=$LATEST_FILE"
echo "pii_log_scan_hit_count=$HIT_COUNT"
echo "pii_log_scan_ok=$SCAN_OK"

if [[ "$SCAN_OK" != "true" && "$ALLOW_HITS" != "true" ]]; then
  exit 1
fi
