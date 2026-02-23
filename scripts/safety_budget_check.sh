#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUDGET_FILE="${BUDGET_FILE:-$ROOT_DIR/safety/budgets.yaml}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/safety}"
ALLOW_MISSING_OPTIONAL=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget-file)
      BUDGET_FILE="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --strict-optional)
      ALLOW_MISSING_OPTIONAL=false
      shift
      ;;
    *)
      echo "unknown option: $1"
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/safety-budget-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/safety-budget-latest.json"

python3 - "$ROOT_DIR" "$BUDGET_FILE" "$REPORT_FILE" "$ALLOW_MISSING_OPTIONAL" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

root = pathlib.Path(sys.argv[1]).resolve()
budget_file = pathlib.Path(sys.argv[2]).resolve()
report_file = pathlib.Path(sys.argv[3]).resolve()
allow_missing_optional = sys.argv[4].lower() == "true"

with open(budget_file, "r", encoding="utf-8") as f:
    cfg = json.load(f)

budgets = cfg.get("budgets", {})
reports_cfg = cfg.get("reports", {})

results = []
violations = []

def load_report(key):
    rel = reports_cfg.get(key)
    if not rel:
        return None, None
    path = root / rel
    if not path.exists():
        return rel, None
    with open(path, "r", encoding="utf-8") as f:
        return rel, json.load(f)

for key, budget in budgets.items():
    required = bool(budget.get("required", False))
    rel_path, payload = load_report(key)

    entry = {
        "check": key,
        "required": required,
        "report_path": rel_path,
        "report_exists": payload is not None,
        "ok": True,
        "details": [],
    }

    if payload is None:
        if required or not allow_missing_optional:
            entry["ok"] = False
            entry["details"].append("missing_report")
            violations.append(f"{key}:missing_report")
        results.append(entry)
        continue

    if key == "load":
        p99 = float(payload.get("order_p99_ms", 0.0))
        err = float(payload.get("order_error_rate", 1.0))
        if p99 > float(budget.get("orderP99MsMax", 0)):
            entry["ok"] = False
            entry["details"].append(f"order_p99_ms={p99} > {budget['orderP99MsMax']}")
        if err > float(budget.get("orderErrorRateMax", 0)):
            entry["ok"] = False
            entry["details"].append(f"order_error_rate={err} > {budget['orderErrorRateMax']}")
    elif key == "dr":
        restore = int(payload.get("restore_time_ms", 0))
        replay = int(payload.get("replay_time_ms", 0))
        if restore > int(budget.get("restoreTimeMsMax", 0)):
            entry["ok"] = False
            entry["details"].append(f"restore_time_ms={restore} > {budget['restoreTimeMsMax']}")
        if replay > int(budget.get("replayTimeMsMax", 0)):
            entry["ok"] = False
            entry["details"].append(f"replay_time_ms={replay} > {budget['replayTimeMsMax']}")
    elif key == "invariants":
        must_ok = bool(budget.get("mustBeOk", True))
        inv_ok = bool(payload.get("ok", False))
        if must_ok and not inv_ok:
            entry["ok"] = False
            entry["details"].append("invariants_not_ok")
    elif key == "invariantsSummary":
        must_clickhouse_ok = bool(budget.get("mustClickhouseBeOkWhenChecked", True))
        must_core_ok = bool(budget.get("mustCoreBeOkWhenChecked", True))
        summary_ok = bool(payload.get("ok", False))
        clickhouse = payload.get("clickhouse", {}) if isinstance(payload, dict) else {}
        clickhouse_status = str(clickhouse.get("status", ""))
        clickhouse_ok = bool(clickhouse.get("ok", False))
        core = payload.get("core", {}) if isinstance(payload, dict) else {}
        core_status = str(core.get("status", ""))
        core_ok = bool(core.get("ok", False))
        if not summary_ok:
            entry["ok"] = False
            entry["details"].append("invariants_summary_not_ok")
        if must_clickhouse_ok and clickhouse_status == "checked" and not clickhouse_ok:
            entry["ok"] = False
            entry["details"].append("clickhouse_invariants_not_ok")
        if must_core_ok and core_status == "checked" and not core_ok:
            entry["ok"] = False
            entry["details"].append("core_seq_invariants_not_ok")
    elif key == "snapshotVerify":
        must_ok = bool(budget.get("mustBeOk", True))
        snap_ok = bool(payload.get("ok", False))
        if must_ok and not snap_ok:
            entry["ok"] = False
            entry["details"].append("snapshot_verify_not_ok")
    elif key == "ws":
        slow = float(payload.get("metrics", {}).get("ws_slow_closes", 0.0))
        dropped = float(payload.get("metrics", {}).get("ws_dropped_msgs", 0.0))
        if slow < float(budget.get("slowClosesMin", 0)):
            entry["ok"] = False
            entry["details"].append(f"ws_slow_closes={slow} < {budget['slowClosesMin']}")
        if dropped < float(budget.get("droppedMsgsMin", 0)):
            entry["ok"] = False
            entry["details"].append(f"ws_dropped_msgs={dropped} < {budget['droppedMsgsMin']}")
    elif key == "wsResume":
        resume_gaps = float(payload.get("metrics", {}).get("ws_resume_gaps", 0.0))
        gap_type = str(payload.get("gap_recovery", {}).get("result_type", ""))
        if resume_gaps < float(budget.get("gapSignalsMin", 0)):
            entry["ok"] = False
            entry["details"].append(f"ws_resume_gaps={resume_gaps} < {budget['gapSignalsMin']}")
        must_have_gap_type = bool(budget.get("mustHaveGapResultType", True))
        if must_have_gap_type and not gap_type:
            entry["ok"] = False
            entry["details"].append("missing_gap_result_type")
        allowed_types = budget.get("allowedGapResultTypes")
        if allowed_types and gap_type and gap_type not in allowed_types:
            entry["ok"] = False
            entry["details"].append(f"unexpected_gap_result_type={gap_type}")
    elif key == "reconciliationSmoke":
        checks = payload.get("checks", {})
        if bool(budget.get("mustConfirmBreach", False)) and not bool(checks.get("breach_confirmed", False)):
            entry["ok"] = False
            entry["details"].append("breach_not_confirmed")
        if bool(budget.get("mustRecover", False)) and not bool(checks.get("recovery_confirmed", False)):
            entry["ok"] = False
            entry["details"].append("recovery_not_confirmed")
        if bool(budget.get("mustReleaseLatch", False)) and not bool(checks.get("latch_released", False)):
            entry["ok"] = False
            entry["details"].append("latch_not_released")
    elif key in {"auditChain", "changeAuditChain"}:
        must_ok = bool(budget.get("mustBeOk", True))
        chain_ok = bool(payload.get("ok", False))
        mode = str(payload.get("mode", ""))
        chain_label = "audit_chain" if key == "auditChain" else "change_audit_chain"
        if must_ok and not chain_ok:
            entry["ok"] = False
            entry["details"].append(f"{chain_label}_not_ok")
        allowed_modes = budget.get("allowedModes")
        if allowed_modes and mode and mode not in allowed_modes:
            entry["ok"] = False
            entry["details"].append(f"{chain_label}_mode_not_allowed={mode}")
    elif key == "piiLogScan":
        must_ok = bool(budget.get("mustBeOk", True))
        scan_ok = bool(payload.get("ok", False))
        hit_count = int(payload.get("hit_count", 0))
        max_hits = int(budget.get("maxHits", 0))
        if must_ok and not scan_ok:
            entry["ok"] = False
            entry["details"].append("pii_log_scan_not_ok")
        if hit_count > max_hits:
            entry["ok"] = False
            entry["details"].append(f"pii_hit_count={hit_count} > {max_hits}")
    elif key == "anomaly":
        must_ok = bool(budget.get("mustBeOk", True))
        anomaly_ok = bool(payload.get("ok", False))
        anomaly_detected = bool(payload.get("anomaly_detected", False))
        if must_ok and not anomaly_ok:
            entry["ok"] = False
            entry["details"].append("anomaly_detector_not_ok")
        if bool(budget.get("mustNotDetectAnomaly", False)) and anomaly_detected:
            entry["ok"] = False
            entry["details"].append("anomaly_detected")

    if not entry["ok"]:
        violations.append(f"{key}:{';'.join(entry['details'])}")
    results.append(entry)

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(violations) == 0,
    "allow_missing_optional": allow_missing_optional,
    "violations": violations,
    "results": results,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

BUDGET_OK="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "safety_budget_report=${REPORT_FILE}"
echo "safety_budget_latest=${LATEST_FILE}"
echo "safety_budget_ok=${BUDGET_OK}"

if [[ "${BUDGET_OK}" != "true" ]]; then
  exit 1
fi
