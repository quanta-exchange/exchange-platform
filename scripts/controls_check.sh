#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTROLS_FILE="$ROOT_DIR/controls/controls.yaml"
OUT_DIR="$ROOT_DIR/build/controls"
ALLOW_MISSING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --controls-file)
      CONTROLS_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --allow-missing)
      ALLOW_MISSING=true
      shift
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
mkdir -p "$OUT_DIR"
REPORT_FILE="$OUT_DIR/controls-check-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/controls-check-latest.json"

python3 - "$ROOT_DIR" "$CONTROLS_FILE" "$REPORT_FILE" <<'PY'
import datetime
import glob
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
controls_file = pathlib.Path(sys.argv[2]).resolve()
report_file = pathlib.Path(sys.argv[3]).resolve()
now_utc = datetime.datetime.now(datetime.timezone.utc)

with open(controls_file, "r", encoding="utf-8") as f:
    payload = json.load(f)

controls = payload.get("controls", [])
results = []
failed_enforced = []
advisory_missing = []
failed_enforced_stale = []
advisory_stale = []

for item in controls:
    cid = str(item.get("id", "UNKNOWN"))
    title = str(item.get("title", ""))
    enforced = bool(item.get("enforced", False))
    evidence_patterns = item.get("required_evidence", []) or []
    max_evidence_age_seconds = item.get("max_evidence_age_seconds")
    if max_evidence_age_seconds is not None:
        max_evidence_age_seconds = int(max_evidence_age_seconds)

    missing = []
    matched = []
    stale = []
    evidence_age_seconds = {}
    for pattern in evidence_patterns:
        pattern = str(pattern)
        matches = sorted(glob.glob(str(root / pattern)))
        if matches:
            matched.append(pattern)
            if max_evidence_age_seconds is not None:
                newest_mtime = max(pathlib.Path(m).stat().st_mtime for m in matches)
                age_seconds = max(0, int(now_utc.timestamp() - newest_mtime))
                evidence_age_seconds[pattern] = age_seconds
                if age_seconds > max_evidence_age_seconds:
                    stale.append(
                        f"{pattern}:age_seconds={age_seconds}>{max_evidence_age_seconds}"
                    )
        else:
            missing.append(pattern)

    ok = len(missing) == 0 and len(stale) == 0
    result = {
        "id": cid,
        "title": title,
        "enforced": enforced,
        "max_evidence_age_seconds": max_evidence_age_seconds,
        "ok": ok,
        "missing_evidence": missing,
        "stale_evidence": stale,
        "evidence_age_seconds": evidence_age_seconds,
        "required_evidence": evidence_patterns,
        "matched_patterns": matched,
    }
    results.append(result)

    if not ok and enforced:
        failed_enforced.append(cid)
    if stale and enforced:
        failed_enforced_stale.append(cid)
    if not ok and not enforced:
        advisory_missing.append(cid)
    if stale and not enforced:
        advisory_stale.append(cid)

report = {
    "generated_at_utc": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(failed_enforced) == 0,
    "total_controls": len(results),
    "enforced_controls": sum(1 for r in results if r["enforced"]),
    "failed_enforced_count": len(failed_enforced),
    "failed_enforced": failed_enforced,
    "failed_enforced_stale_count": len(failed_enforced_stale),
    "failed_enforced_stale": failed_enforced_stale,
    "advisory_missing_count": len(advisory_missing),
    "advisory_missing": advisory_missing,
    "advisory_stale_count": len(advisory_stale),
    "advisory_stale": advisory_stale,
    "results": results,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

CHECK_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

FAILED_ENFORCED_COUNT="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(int(payload.get("failed_enforced_count", 0)))
PY
)"

echo "controls_check_report=${REPORT_FILE}"
echo "controls_check_latest=${LATEST_FILE}"
echo "controls_check_ok=${CHECK_OK}"
echo "controls_check_failed_enforced=${FAILED_ENFORCED_COUNT}"

if [[ "${CHECK_OK}" != "true" && "${ALLOW_MISSING}" != "true" ]]; then
  echo "controls check failed for enforced controls (use --allow-missing to bypass)" >&2
  exit 1
fi
