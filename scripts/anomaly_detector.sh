#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/anomaly}"
EDGE_URL="${EDGE_URL:-http://localhost:8080}"
LEDGER_URL="${LEDGER_URL:-http://localhost:8082}"
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_RETRIES="${WEBHOOK_RETRIES:-10}"
WEBHOOK_RETRY_DELAY_MS="${WEBHOOK_RETRY_DELAY_MS:-200}"

LAG_THRESHOLD="${LAG_THRESHOLD:-10}"
BREACH_ACTIVE_THRESHOLD="${BREACH_ACTIVE_THRESHOLD:-1}"
WS_DROPPED_THRESHOLD="${WS_DROPPED_THRESHOLD:-100}"
WS_SLOW_CLOSES_THRESHOLD="${WS_SLOW_CLOSES_THRESHOLD:-20}"
WS_RESUME_GAPS_THRESHOLD="${WS_RESUME_GAPS_THRESHOLD:-20}"

ALLOW_ANOMALY=false
FORCE_ANOMALY=false
FORCE_REASON="${FORCE_REASON:-forced_anomaly_drill}"
REQUIRE_WEBHOOK_DELIVERY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --edge-url)
      EDGE_URL="$2"
      shift 2
      ;;
    --ledger-url)
      LEDGER_URL="$2"
      shift 2
      ;;
    --webhook-url)
      WEBHOOK_URL="$2"
      shift 2
      ;;
    --webhook-retries)
      WEBHOOK_RETRIES="$2"
      shift 2
      ;;
    --webhook-retry-delay-ms)
      WEBHOOK_RETRY_DELAY_MS="$2"
      shift 2
      ;;
    --lag-threshold)
      LAG_THRESHOLD="$2"
      shift 2
      ;;
    --breach-threshold)
      BREACH_ACTIVE_THRESHOLD="$2"
      shift 2
      ;;
    --ws-dropped-threshold)
      WS_DROPPED_THRESHOLD="$2"
      shift 2
      ;;
    --ws-slow-closes-threshold)
      WS_SLOW_CLOSES_THRESHOLD="$2"
      shift 2
      ;;
    --ws-resume-gaps-threshold)
      WS_RESUME_GAPS_THRESHOLD="$2"
      shift 2
      ;;
    --allow-anomaly)
      ALLOW_ANOMALY=true
      shift
      ;;
    --force-anomaly)
      FORCE_ANOMALY=true
      shift
      ;;
    --force-reason)
      FORCE_REASON="$2"
      shift 2
      ;;
    --require-webhook-delivery)
      REQUIRE_WEBHOOK_DELIVERY=true
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
REPORT_FILE="$OUT_DIR/anomaly-detector-${TS_ID}.json"
LATEST_FILE="$OUT_DIR/anomaly-detector-latest.json"

EDGE_METRICS_FILE="$OUT_DIR/edge-metrics-${TS_ID}.txt"
LEDGER_METRICS_FILE="$OUT_DIR/ledger-metrics-${TS_ID}.txt"

curl -fsS "$EDGE_URL/metrics" >"$EDGE_METRICS_FILE" 2>/dev/null || true
curl -fsS "$LEDGER_URL/metrics" >"$LEDGER_METRICS_FILE" 2>/dev/null || true

python3 - "$REPORT_FILE" "$EDGE_METRICS_FILE" "$LEDGER_METRICS_FILE" "$LAG_THRESHOLD" "$BREACH_ACTIVE_THRESHOLD" "$WS_DROPPED_THRESHOLD" "$WS_SLOW_CLOSES_THRESHOLD" "$WS_RESUME_GAPS_THRESHOLD" "$FORCE_ANOMALY" "$FORCE_REASON" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

report_file = pathlib.Path(sys.argv[1]).resolve()
edge_metrics_file = pathlib.Path(sys.argv[2]).resolve()
ledger_metrics_file = pathlib.Path(sys.argv[3]).resolve()
lag_threshold = float(sys.argv[4])
breach_threshold = float(sys.argv[5])
ws_dropped_threshold = float(sys.argv[6])
ws_slow_threshold = float(sys.argv[7])
ws_resume_threshold = float(sys.argv[8])
force_anomaly = sys.argv[9].lower() == "true"
force_reason = sys.argv[10]


def parse_metrics(path: pathlib.Path):
    values = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        key = parts[0]
        value = parts[1]
        try:
            values[key] = float(value)
        except Exception:
            continue
    return values


def metric_value(name: str, *sources):
    for source in sources:
        if name in source:
            return source[name]
    return 0.0


edge = parse_metrics(edge_metrics_file)
ledger = parse_metrics(ledger_metrics_file)

rules = [
    {
        "id": "ledger_reconciliation_breach",
        "metric": "reconciliation_breach_active",
        "value": metric_value("reconciliation_breach_active", ledger),
        "threshold": breach_threshold,
        "severity": 3,
        "description": "Ledger reconciliation breach active count exceeded threshold",
    },
    {
        "id": "ledger_reconciliation_lag_max",
        "metric": "reconciliation_lag_max",
        "value": metric_value("reconciliation_lag_max", ledger),
        "threshold": lag_threshold,
        "severity": 2,
        "description": "Ledger reconciliation lag max exceeded threshold",
    },
    {
        "id": "ws_dropped_msgs",
        "metric": "ws_dropped_msgs",
        "value": metric_value("ws_dropped_msgs", edge),
        "threshold": ws_dropped_threshold,
        "severity": 2,
        "description": "WS dropped messages exceeded threshold",
    },
    {
        "id": "ws_slow_closes",
        "metric": "ws_slow_closes",
        "value": metric_value("ws_slow_closes", edge),
        "threshold": ws_slow_threshold,
        "severity": 1,
        "description": "WS slow closes exceeded threshold",
    },
    {
        "id": "ws_resume_gaps",
        "metric": "ws_resume_gaps",
        "value": metric_value("ws_resume_gaps", edge),
        "threshold": ws_resume_threshold,
        "severity": 1,
        "description": "WS resume gaps exceeded threshold",
    },
]

anomalies = []
for rule in rules:
    if rule["value"] >= rule["threshold"]:
        anomalies.append(
            {
                "id": rule["id"],
                "metric": rule["metric"],
                "value": rule["value"],
                "threshold": rule["threshold"],
                "severity": rule["severity"],
                "description": rule["description"],
            }
        )

if force_anomaly:
    anomalies.append(
        {
            "id": "forced_anomaly",
            "metric": "forced",
            "value": 1,
            "threshold": 1,
            "severity": 3,
            "description": force_reason,
        }
    )

max_severity = max((a["severity"] for a in anomalies), default=0)
recommended_action = "NONE"
if max_severity >= 3:
    recommended_action = "WITHDRAW_HALT"
elif max_severity == 2:
    recommended_action = "CANCEL_ONLY"
elif max_severity == 1:
    recommended_action = "INVESTIGATE"

payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": len(anomalies) == 0,
    "anomaly_detected": len(anomalies) > 0,
    "recommended_action": recommended_action,
    "edge_metrics_file": str(edge_metrics_file),
    "ledger_metrics_file": str(ledger_metrics_file),
    "metrics": {
        "reconciliation_breach_active": metric_value("reconciliation_breach_active", ledger),
        "reconciliation_lag_max": metric_value("reconciliation_lag_max", ledger),
        "ws_dropped_msgs": metric_value("ws_dropped_msgs", edge),
        "ws_slow_closes": metric_value("ws_slow_closes", edge),
        "ws_resume_gaps": metric_value("ws_resume_gaps", edge),
    },
    "thresholds": {
        "reconciliation_breach_active": breach_threshold,
        "reconciliation_lag_max": lag_threshold,
        "ws_dropped_msgs": ws_dropped_threshold,
        "ws_slow_closes": ws_slow_threshold,
        "ws_resume_gaps": ws_resume_threshold,
    },
    "anomalies": anomalies,
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with open(report_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

ANOMALY_DETECTED="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("anomaly_detected") else "false")
PY
)"

RECOMMENDED_ACTION="$(
  python3 - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print(payload.get("recommended_action", "NONE"))
PY
)"

WEBHOOK_SENT=false
WEBHOOK_ERROR=""
if [[ -n "$WEBHOOK_URL" ]]; then
  for _ in $(seq 1 "$WEBHOOK_RETRIES"); do
    if curl -fsS -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      --data-binary "@$REPORT_FILE" >/dev/null 2>/dev/null; then
      WEBHOOK_SENT=true
      break
    fi
    python3 - "$WEBHOOK_RETRY_DELAY_MS" <<'PY'
import sys
import time
delay_ms = float(sys.argv[1])
time.sleep(max(0.0, delay_ms) / 1000.0)
PY
  done
  if [[ "$WEBHOOK_SENT" != "true" ]]; then
    WEBHOOK_ERROR="webhook_delivery_failed"
  fi
fi

echo "anomaly_report=$REPORT_FILE"
echo "anomaly_latest=$LATEST_FILE"
echo "anomaly_detected=$ANOMALY_DETECTED"
echo "anomaly_recommended_action=$RECOMMENDED_ACTION"
echo "anomaly_webhook_sent=$WEBHOOK_SENT"
if [[ -n "$WEBHOOK_ERROR" ]]; then
  echo "anomaly_webhook_error=$WEBHOOK_ERROR"
fi

if [[ "$REQUIRE_WEBHOOK_DELIVERY" == "true" && "$ANOMALY_DETECTED" == "true" && "$WEBHOOK_SENT" != "true" ]]; then
  exit 1
fi
if [[ "$ANOMALY_DETECTED" == "true" && "$ALLOW_ANOMALY" != "true" ]]; then
  exit 1
fi
