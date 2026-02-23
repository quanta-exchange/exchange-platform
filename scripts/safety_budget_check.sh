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
freshness_cfg = cfg.get("freshness", {}) if isinstance(cfg.get("freshness"), dict) else {}

freshness_default_max_age = freshness_cfg.get("defaultMaxAgeSeconds")
if freshness_default_max_age is not None:
    freshness_default_max_age = int(freshness_default_max_age)

results = []
violations = []

def parse_utc(raw):
    if raw is None:
        return None
    if isinstance(raw, (int, float)):
        val = float(raw)
        # Accept both epoch seconds and epoch milliseconds.
        if val > 1_000_000_000_000:
            val = val / 1000.0
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

def resolve_report_time(payload, path):
    if isinstance(payload, dict):
        for key in ("generated_at_utc", "timestamp_utc", "timestamp", "ts"):
            if key not in payload:
                continue
            try:
                parsed = parse_utc(payload.get(key))
            except Exception:
                parsed = None
            if parsed is not None:
                return parsed, key
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc), "file_mtime"

def load_report(key):
    rel = reports_cfg.get(key)
    if not rel:
        return None, None, None
    path = root / rel
    if not path.exists():
        return rel, None, path
    with open(path, "r", encoding="utf-8") as f:
        return rel, json.load(f), path

for key, budget in budgets.items():
    required = bool(budget.get("required", False))
    rel_path, payload, report_path = load_report(key)

    entry = {
        "check": key,
        "required": required,
        "report_path": rel_path,
        "report_exists": payload is not None,
        "report_generated_at_utc": None,
        "report_time_source": None,
        "age_seconds": None,
        "max_age_seconds": None,
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

    max_age_seconds = budget.get("maxAgeSeconds", freshness_default_max_age)
    if max_age_seconds is not None:
        max_age_seconds = int(max_age_seconds)
        entry["max_age_seconds"] = max_age_seconds
        report_ts, report_ts_source = resolve_report_time(payload, report_path)
        age_seconds = max(0, int((datetime.now(timezone.utc) - report_ts).total_seconds()))
        entry["report_generated_at_utc"] = report_ts.strftime("%Y-%m-%dT%H:%M:%SZ")
        entry["report_time_source"] = report_ts_source
        entry["age_seconds"] = age_seconds
        if age_seconds > max_age_seconds:
            entry["ok"] = False
            entry["details"].append(f"stale_report age_seconds={age_seconds} > {max_age_seconds}")

    if key == "load":
        p99 = float(payload.get("order_p99_ms", 0.0))
        err = float(payload.get("order_error_rate", 1.0))
        thresholds_checked = bool(payload.get("thresholds_checked", False))
        thresholds_passed = bool(payload.get("thresholds_passed", False))
        orders_succeeded = int(payload.get("orders_succeeded", 0))
        if bool(budget.get("mustThresholdsChecked", False)) and not thresholds_checked:
            entry["ok"] = False
            entry["details"].append("load_thresholds_not_checked")
        if bool(budget.get("mustThresholdsPass", False)) and thresholds_checked and not thresholds_passed:
            entry["ok"] = False
            entry["details"].append("load_thresholds_not_passed")
        min_orders_succeeded = budget.get("minOrdersSucceeded")
        if min_orders_succeeded is not None and orders_succeeded < int(min_orders_succeeded):
            entry["ok"] = False
            entry["details"].append(
                f"orders_succeeded={orders_succeeded} < {int(min_orders_succeeded)}"
            )
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
    elif key == "policySmoke":
        must_ok = bool(budget.get("mustBeOk", True))
        policy_ok = bool(payload.get("ok", False))
        if must_ok and not policy_ok:
            entry["ok"] = False
            entry["details"].append("policy_smoke_not_ok")
    elif key == "policyTamper":
        must_ok = bool(budget.get("mustBeOk", True))
        tamper_ok = bool(payload.get("ok", False))
        tamper_detected = bool(payload.get("tamper_detected", False))
        if must_ok and not tamper_ok:
            entry["ok"] = False
            entry["details"].append("policy_tamper_proof_not_ok")
        if bool(budget.get("mustDetectTamper", True)) and not tamper_detected:
            entry["ok"] = False
            entry["details"].append("policy_tamper_not_detected")
    elif key == "chaosNetworkPartition":
        must_ok = bool(budget.get("mustBeOk", True))
        partition_ok = bool(payload.get("ok", False))
        connectivity = payload.get("connectivity", {}) if isinstance(payload, dict) else {}
        before_reachable = bool(connectivity.get("before_partition_broker_reachable", False))
        during_reachable = bool(connectivity.get("during_partition_broker_reachable", True))
        after_reachable = bool(connectivity.get("after_recovery_broker_reachable", False))
        if must_ok and not partition_ok:
            entry["ok"] = False
            entry["details"].append("chaos_network_partition_not_ok")
        if not before_reachable:
            entry["ok"] = False
            entry["details"].append("chaos_network_partition_before_not_reachable")
        if bool(budget.get("mustLoseConnectivity", True)) and during_reachable:
            entry["ok"] = False
            entry["details"].append("chaos_network_partition_did_not_lose_connectivity")
        if bool(budget.get("mustRecoverConnectivity", True)) and not after_reachable:
            entry["ok"] = False
            entry["details"].append("chaos_network_partition_did_not_recover_connectivity")
    elif key == "chaosRedpandaBounce":
        must_ok = bool(budget.get("mustBeOk", True))
        bounce_ok = bool(payload.get("ok", False))
        connectivity = payload.get("connectivity", {}) if isinstance(payload, dict) else {}
        before_reachable = bool(connectivity.get("before_stop_broker_reachable", False))
        during_reachable = bool(connectivity.get("during_stop_broker_reachable", True))
        after_reachable = bool(connectivity.get("after_restart_broker_reachable", False))
        post_consume_ok = bool(connectivity.get("post_restart_consume_ok", False))
        if must_ok and not bounce_ok:
            entry["ok"] = False
            entry["details"].append("chaos_redpanda_bounce_not_ok")
        if not before_reachable:
            entry["ok"] = False
            entry["details"].append("chaos_redpanda_bounce_before_not_reachable")
        if bool(budget.get("mustLoseConnectivity", True)) and during_reachable:
            entry["ok"] = False
            entry["details"].append("chaos_redpanda_bounce_did_not_lose_connectivity")
        if bool(budget.get("mustRecoverConnectivity", True)) and not after_reachable:
            entry["ok"] = False
            entry["details"].append("chaos_redpanda_bounce_did_not_recover_connectivity")
        if bool(budget.get("mustConsumeAfterRecovery", True)) and not post_consume_ok:
            entry["ok"] = False
            entry["details"].append("chaos_redpanda_bounce_no_post_recovery_consume")
    elif key == "adversarial":
        must_ok = bool(budget.get("mustBeOk", True))
        adversarial_ok = bool(payload.get("ok", False))
        if must_ok and not adversarial_ok:
            entry["ok"] = False
            entry["details"].append("adversarial_bundle_not_ok")

        steps = payload.get("steps", []) if isinstance(payload, dict) else []
        status_by_name = {}
        if isinstance(steps, list):
            for step in steps:
                if not isinstance(step, dict):
                    continue
                name = str(step.get("name", ""))
                if not name:
                    continue
                status_by_name[name] = str(step.get("status", ""))

        required_steps = budget.get("mustPassSteps", [])
        if isinstance(required_steps, list):
            for step_name in required_steps:
                name = str(step_name)
                status = status_by_name.get(name)
                if status != "pass":
                    entry["ok"] = False
                    entry["details"].append(
                        f"adversarial_step_{name}_status={status or 'missing'}"
                    )

        exactly_once_status = status_by_name.get("exactly_once_stress")
        if (
            exactly_once_status == "skip"
            and not bool(budget.get("allowExactlyOnceSkip", True))
        ):
            entry["ok"] = False
            entry["details"].append("adversarial_exactly_once_skip_not_allowed")

    if not entry["ok"]:
        violations.append(f"{key}:{';'.join(entry['details'])}")
    results.append(entry)

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(violations) == 0,
    "allow_missing_optional": allow_missing_optional,
    "freshness_default_max_age_seconds": freshness_default_max_age,
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
