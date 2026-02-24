#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/release-gate}"
RELEASE_GATE_REPORT="${RELEASE_GATE_REPORT:-$ROOT_DIR/build/release-gate/release-gate-latest.json}"
FALLBACK_SMOKE_REPORT="${FALLBACK_SMOKE_REPORT:-$ROOT_DIR/build/release-gate-smoke/release-gate-fallback-smoke-latest.json}"
EXPECT_REQUIRE_RUNBOOK_CONTEXT=true
ALLOW_MISSING=false
PYTHON_BIN="${PYTHON_BIN:-python3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --release-gate-report)
      RELEASE_GATE_REPORT="$2"
      shift 2
      ;;
    --fallback-smoke-report)
      FALLBACK_SMOKE_REPORT="$2"
      shift 2
      ;;
    --expect-require-runbook-context)
      EXPECT_REQUIRE_RUNBOOK_CONTEXT=true
      shift
      ;;
    --allow-require-runbook-context-false)
      EXPECT_REQUIRE_RUNBOOK_CONTEXT=false
      shift
      ;;
    --allow-missing)
      ALLOW_MISSING=true
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
REPORT_FILE="$OUT_DIR/prove-release-gate-context-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/prove-release-gate-context-latest.json"

"$PYTHON_BIN" - "$REPORT_FILE" "$RELEASE_GATE_REPORT" "$FALLBACK_SMOKE_REPORT" "$EXPECT_REQUIRE_RUNBOOK_CONTEXT" "$ALLOW_MISSING" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
release_gate_report = pathlib.Path(sys.argv[2]).resolve()
fallback_smoke_report = pathlib.Path(sys.argv[3]).resolve()
expect_require_runbook_context = sys.argv[4].lower() == "true"
allow_missing = sys.argv[5].lower() == "true"


def load_optional(path: pathlib.Path):
    if not path.exists():
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


release_payload = load_optional(release_gate_report)
fallback_payload = load_optional(fallback_smoke_report)

release_present = release_payload is not None
fallback_present = fallback_payload is not None

release_ok = (
    bool(release_payload.get("ok", False)) if isinstance(release_payload, dict) else None
)
require_runbook_context = (
    release_payload.get("require_runbook_context")
    if isinstance(release_payload, dict)
    else None
)
runbook_context_backfill_ok = (
    release_payload.get("runbook_context_backfill_ok")
    if isinstance(release_payload, dict)
    else None
)
runbook_context_missing = (
    list(release_payload.get("runbook_context_missing", []) or [])
    if isinstance(release_payload, dict)
    else []
)
runbook_context_missing_count = len(runbook_context_missing)

fallback_ok = (
    bool(fallback_payload.get("ok", False))
    if isinstance(fallback_payload, dict)
    else None
)
fallback_missing_fields = (
    list(fallback_payload.get("missing_fields", []) or [])
    if isinstance(fallback_payload, dict)
    else []
)
fallback_missing_fields_count = len(fallback_missing_fields)
fallback_used_embedded_check = (
    fallback_payload.get("used_release_gate_embedded_check")
    if isinstance(fallback_payload, dict)
    else None
)
fallback_release_gate_context_backfill_ok = (
    fallback_payload.get("release_gate_runbook_context_backfill_ok")
    if isinstance(fallback_payload, dict)
    else None
)

checks = {}
checks["release_report_present"] = release_present or allow_missing
checks["fallback_report_present"] = fallback_present or allow_missing
checks["release_context_backfill_ok"] = (
    runbook_context_backfill_ok is True if release_present else allow_missing
)
checks["release_context_missing_fields"] = (
    runbook_context_missing_count == 0 if release_present else allow_missing
)
checks["fallback_ok"] = (fallback_ok is True) if fallback_present else allow_missing
checks["fallback_missing_fields"] = (
    fallback_missing_fields_count == 0 if fallback_present else allow_missing
)
checks["fallback_context_backfill_ok"] = (
    fallback_release_gate_context_backfill_ok is True
    if fallback_present
    else allow_missing
)

if expect_require_runbook_context:
    checks["release_require_runbook_context"] = (
        require_runbook_context is True if release_present else allow_missing
    )
else:
    checks["release_require_runbook_context"] = True

failed_checks = sorted([name for name, value in checks.items() if not value])
ok = len(failed_checks) == 0

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "failed_checks": failed_checks,
    "expect_require_runbook_context": expect_require_runbook_context,
    "allow_missing": allow_missing,
    "release_gate": {
        "path": str(release_gate_report),
        "present": release_present,
        "ok": release_ok,
        "require_runbook_context": require_runbook_context,
        "runbook_context_backfill_ok": runbook_context_backfill_ok,
        "runbook_context_missing_count": runbook_context_missing_count,
        "runbook_context_missing": runbook_context_missing,
    },
    "fallback_smoke": {
        "path": str(fallback_smoke_report),
        "present": fallback_present,
        "ok": fallback_ok,
        "used_release_gate_embedded_check": fallback_used_embedded_check,
        "release_gate_runbook_context_backfill_ok": fallback_release_gate_context_backfill_ok,
        "missing_fields_count": fallback_missing_fields_count,
        "missing_fields": fallback_missing_fields,
    },
    "checks": checks,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

PROOF_OK="$("$PYTHON_BIN" - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "prove_release_gate_context_report=$REPORT_FILE"
echo "prove_release_gate_context_latest=$LATEST_FILE"
echo "prove_release_gate_context_ok=$PROOF_OK"

if [[ "$PROOF_OK" != "true" ]]; then
  exit 1
fi
