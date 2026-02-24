#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/metrics}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
PROM_FILE="$OUT_DIR/proof-health-${TS_ID}.prom"
PROM_LATEST="$OUT_DIR/proof-health-latest.prom"
JSON_FILE="$OUT_DIR/proof-health-${TS_ID}.json"
JSON_LATEST="$OUT_DIR/proof-health-latest.json"

"$PYTHON_BIN" - "$ROOT_DIR" "$PROM_FILE" "$JSON_FILE" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1]).resolve()
prom_file = pathlib.Path(sys.argv[2]).resolve()
json_file = pathlib.Path(sys.argv[3]).resolve()

sources = {
    "determinism": "build/determinism/prove-determinism-latest.json",
    "idempotency_scope": "build/idempotency/prove-idempotency-latest.json",
    "idempotency_key_format": "build/idempotency/prove-idempotency-key-format-latest.json",
    "latch_approval": "build/latch/prove-latch-approval-latest.json",
    "exactly_once_million": "build/exactly-once/prove-exactly-once-million-latest.json",
    "mapping_integrity": "build/compliance/prove-mapping-integrity-latest.json",
    "mapping_coverage": "build/compliance/prove-mapping-coverage-latest.json",
    "mapping_coverage_metrics": "build/metrics/mapping-coverage-latest.json",
    "runbook_exactly_once_million": "build/runbooks/exactly-once-million-latest.json",
    "runbook_mapping_integrity": "build/runbooks/mapping-integrity-latest.json",
    "runbook_mapping_coverage": "build/runbooks/mapping-coverage-latest.json",
    "runbook_idempotency_latch": "build/runbooks/idempotency-latch-latest.json",
    "runbook_idempotency_key_format": "build/runbooks/idempotency-key-format-latest.json",
    "runbook_proof_health": "build/runbooks/proof-health-latest.json",
}

def parse_utc(raw):
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        val = float(raw)
        if val > 1_000_000_000_000:
            val /= 1000.0
        return datetime.fromtimestamp(val, tz=timezone.utc)
    if not isinstance(raw, str):
        return None
    text = raw.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)

def read_payload(path):
    if not path.exists():
        return None, None, None
    with open(path, "r", encoding="utf-8") as f:
        payload = json.load(f)
    ts = None
    ts_source = None
    if isinstance(payload, dict):
        for key in ("generated_at_utc", "timestamp_utc", "timestamp", "ts"):
            ts = parse_utc(payload.get(key))
            if ts is not None:
                ts_source = key
                break
    if ts is None:
        ts = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
        ts_source = "file_mtime"
    return payload, ts, ts_source

tracked = {}
runbook_actions = []
now = datetime.now(timezone.utc)
error_count = 0
failing_count = 0
present_count = 0
missing_count = 0

for name, rel in sources.items():
    path = root / rel
    payload, ts, ts_source = read_payload(path)
    present = payload is not None
    ok = False
    if present:
        present_count += 1
        if isinstance(payload, dict):
            if "ok" in payload:
                ok = bool(payload.get("ok", False))
            elif name.startswith("runbook_"):
                # runbook summary payloads keep proof semantics.
                if name == "runbook_idempotency_latch":
                    ok = bool(payload.get("idempotency_ok", False) and payload.get("latch_ok", False))
                elif name == "runbook_idempotency_key_format":
                    ok = bool(payload.get("proof_ok", False))
                elif name == "runbook_proof_health":
                    ok = bool(payload.get("proof_health_ok", False))
                else:
                    ok = bool(payload.get("proof_ok", False))
            else:
                ok = False
        if not ok:
            failing_count += 1
        action = payload.get("recommended_action") if isinstance(payload, dict) else None
        if action:
            runbook_actions.append((name, str(action)))
    else:
        missing_count += 1
    age_seconds = None
    if ts is not None:
        age_seconds = max(0, int((now - ts).total_seconds()))
    tracked[name] = {
        "path": str(path),
        "present": present,
        "ok": ok,
        "age_seconds": age_seconds,
        "time_source": ts_source,
    }

lines = []
lines.append("# HELP proof_health_artifact_present Whether the latest proof artifact file is present (1=yes, 0=no).")
lines.append("# TYPE proof_health_artifact_present gauge")
lines.append("# HELP proof_health_artifact_ok Whether the latest proof artifact reports success (1=yes, 0=no).")
lines.append("# TYPE proof_health_artifact_ok gauge")
lines.append("# HELP proof_health_artifact_age_seconds Age in seconds of the latest proof artifact.")
lines.append("# TYPE proof_health_artifact_age_seconds gauge")
lines.append("# HELP proof_health_runbook_recommended_action Current recommended action emitted by runbook summaries.")
lines.append("# TYPE proof_health_runbook_recommended_action gauge")
lines.append("# HELP proof_health_overall_ok Whether proof health is fully green (no missing/failing artifacts).")
lines.append("# TYPE proof_health_overall_ok gauge")
lines.append("# HELP proof_health_missing_count Number of missing latest proof artifacts.")
lines.append("# TYPE proof_health_missing_count gauge")
lines.append("# HELP proof_health_failing_count Number of present latest proof artifacts that report non-ok.")
lines.append("# TYPE proof_health_failing_count gauge")
for name, entry in tracked.items():
    present = 1 if entry["present"] else 0
    ok = 1 if entry["ok"] else 0
    age = entry["age_seconds"] if entry["age_seconds"] is not None else -1
    lines.append(f'proof_health_artifact_present{{proof="{name}"}} {present}')
    lines.append(f'proof_health_artifact_ok{{proof="{name}"}} {ok}')
    lines.append(f'proof_health_artifact_age_seconds{{proof="{name}"}} {age}')
for runbook, action in runbook_actions:
    lines.append(
        f'proof_health_runbook_recommended_action{{runbook="{runbook}",action="{action}"}} 1'
    )
health_ok = missing_count == 0 and failing_count == 0
lines.append(f"proof_health_overall_ok {1 if health_ok else 0}")
lines.append(f"proof_health_missing_count {missing_count}")
lines.append(f"proof_health_failing_count {failing_count}")

prom_file.parent.mkdir(parents=True, exist_ok=True)
with open(prom_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

payload = {
    "generated_at_utc": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": health_ok,
    "export_ok": error_count == 0,
    "health_ok": health_ok,
    "error_count": error_count,
    "tracked_count": len(tracked),
    "present_count": present_count,
    "missing_count": missing_count,
    "failing_count": failing_count,
    "tracked": tracked,
    "runbook_recommended_actions": [
        {"runbook": runbook, "action": action} for runbook, action in runbook_actions
    ],
    "prom_file": str(prom_file),
}
with open(json_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$PROM_FILE" "$PROM_LATEST"
cp "$JSON_FILE" "$JSON_LATEST"

METRICS_OK="$("$PYTHON_BIN" - "$JSON_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("export_ok") else "false")
PY
)"

echo "proof_health_metrics_report=$JSON_FILE"
echo "proof_health_metrics_latest=$JSON_LATEST"
echo "proof_health_metrics_prom=$PROM_FILE"
echo "proof_health_metrics_prom_latest=$PROM_LATEST"
echo "proof_health_metrics_ok=$METRICS_OK"

if [[ "$METRICS_OK" != "true" ]]; then
  exit 1
fi
