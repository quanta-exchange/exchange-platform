#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/transparency}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/transparency-report-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/transparency-report-latest.json"

python3 - "$ROOT_DIR" "$REPORT_FILE" <<'PY'
import json
import pathlib
import re
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1]).resolve()
report_file = pathlib.Path(sys.argv[2]).resolve()

def read_json(rel_path):
    path = root / rel_path
    if not path.exists():
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

load = read_json("build/load/load-smoke.json")
dr = read_json("build/dr/dr-report.json")
invariants = read_json("build/invariants/ledger-invariants.json")
core_invariants = read_json("build/invariants/core-invariants.json")
invariants_summary = read_json("build/invariants/invariants-summary.json")
ws = read_json("build/ws/ws-smoke.json")
safety_budget = read_json("build/safety/safety-budget-latest.json")
snapshot_verify = read_json("build/snapshot/snapshot-verify-latest.json")
controls = read_json("build/controls/controls-check-latest.json")
compliance = read_json("build/compliance/compliance-evidence-latest.json")

sources = {
    "load": load,
    "dr": dr,
    "invariants": invariants,
    "core_invariants": core_invariants,
    "invariants_summary": invariants_summary,
    "ws": ws,
    "safety_budget": safety_budget,
    "snapshot_verify": snapshot_verify,
    "controls": controls,
    "compliance": compliance,
}

email_pattern = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
suspicious_key_names = {
    "password",
    "secret",
    "privatekey",
    "private_key",
    "sessiontoken",
    "session_token",
    "apikey",
    "api_key",
    "accesskey",
    "access_key",
}

pii_hits = []
for name, payload in sources.items():
    if payload is None:
        continue

    def scan(value, path):
        if isinstance(value, dict):
            for k, v in value.items():
                normalized = re.sub(r"[^a-z0-9_]", "", str(k).lower())
                if normalized in suspicious_key_names:
                    if isinstance(v, str) and v.strip():
                        pii_hits.append(f"{name}:key:{'.'.join(path + [str(k)])}")
                scan(v, path + [str(k)])
            return
        if isinstance(value, list):
            for idx, item in enumerate(value):
                scan(item, path + [str(idx)])
            return
        if isinstance(value, str) and email_pattern.search(value):
            pii_hits.append(f"{name}:email:{'.'.join(path)}")

    scan(payload, [])

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(pii_hits) == 0,
    "summary": {
        "availability_proxy": {
            "load_thresholds_passed": bool(load.get("thresholds_passed")) if load else None,
            "order_p99_ms": float(load.get("order_p99_ms")) if load and load.get("order_p99_ms") is not None else None,
        },
        "integrity_proxy": {
            "invariants_ok": bool(invariants.get("ok")) if invariants else None,
            "core_invariants_ok": bool(core_invariants.get("ok")) if core_invariants else None,
            "core_order_transition_violations": int(core_invariants.get("order_transition_violations")) if core_invariants and core_invariants.get("order_transition_violations") is not None else None,
            "clickhouse_invariants_ok": bool(invariants_summary.get("clickhouse", {}).get("ok")) if invariants_summary else None,
            "dr_invariant_violations": int(dr.get("invariant_violations")) if dr and dr.get("invariant_violations") is not None else None,
            "safety_budget_ok": bool(safety_budget.get("ok")) if safety_budget else None,
            "snapshot_verify_ok": bool(snapshot_verify.get("ok")) if snapshot_verify else None,
        },
        "ws_proxy": {
            "ws_dropped_msgs": float(ws.get("metrics", {}).get("ws_dropped_msgs")) if ws else None,
            "ws_slow_closes": float(ws.get("metrics", {}).get("ws_slow_closes")) if ws else None,
        },
        "governance_proxy": {
            "controls_ok": bool(controls.get("ok")) if controls else None,
            "compliance_ok": bool(compliance.get("ok")) if compliance else None,
        },
    },
    "pii_scan": {
        "passed": len(pii_hits) == 0,
        "hits": pii_hits,
    },
    "sources": {
        "load": "build/load/load-smoke.json",
        "dr": "build/dr/dr-report.json",
        "invariants": "build/invariants/ledger-invariants.json",
        "core_invariants": "build/invariants/core-invariants.json",
        "invariants_summary": "build/invariants/invariants-summary.json",
        "ws": "build/ws/ws-smoke.json",
        "safety_budget": "build/safety/safety-budget-latest.json",
        "snapshot_verify": "build/snapshot/snapshot-verify-latest.json",
        "controls": "build/controls/controls-check-latest.json",
        "compliance": "build/compliance/compliance-evidence-latest.json",
    },
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

REPORT_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "transparency_report_file=${REPORT_FILE}"
echo "transparency_report_latest=${LATEST_FILE}"
echo "transparency_report_ok=${REPORT_OK}"

if [[ "${REPORT_OK}" != "true" ]]; then
  exit 1
fi
