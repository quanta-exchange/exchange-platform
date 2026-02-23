#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/status}"
REPORT_NAME=""
STRICT=false
PYTHON_BIN="${PYTHON_BIN:-python3}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/infra/compose/docker-compose.yml}"

CORE_HOST="${CORE_HOST:-localhost}"
CORE_PORT="${CORE_PORT:-50051}"
EDGE_URL="${EDGE_URL:-http://localhost:8080}"
LEDGER_URL="${LEDGER_URL:-http://localhost:8082}"
KAFKA_BROKER="${KAFKA_BROKER:-localhost:29092}"
LEDGER_ADMIN_TOKEN="${LEDGER_ADMIN_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=true
      shift
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --report-name)
      REPORT_NAME="$2"
      shift 2
      ;;
    --core-host)
      CORE_HOST="$2"
      shift 2
      ;;
    --core-port)
      CORE_PORT="$2"
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
    --kafka-broker)
      KAFKA_BROKER="$2"
      shift 2
      ;;
    --compose-file)
      COMPOSE_FILE="$2"
      shift 2
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
if [[ -z "$REPORT_NAME" ]]; then
  TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
  REPORT_NAME="system-status-$TS_ID.json"
fi
REPORT_FILE="$OUT_DIR/$REPORT_NAME"
LATEST_FILE="$OUT_DIR/system-status-latest.json"

"$PYTHON_BIN" - "$ROOT_DIR" "$REPORT_FILE" "$CORE_HOST" "$CORE_PORT" "$EDGE_URL" "$LEDGER_URL" "$KAFKA_BROKER" "$COMPOSE_FILE" "$LEDGER_ADMIN_TOKEN" <<'PY'
import json
import pathlib
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urljoin

root_dir = pathlib.Path(sys.argv[1]).resolve()
report_file = sys.argv[2]
core_host = sys.argv[3]
core_port = int(sys.argv[4])
edge_url = sys.argv[5].rstrip("/")
ledger_url = sys.argv[6].rstrip("/")
kafka_broker = sys.argv[7]
compose_file = sys.argv[8]
ledger_admin_token = sys.argv[9]


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def tcp_check(host: str, port: int, timeout: float = 1.5):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, None
    except OSError as exc:
        return False, str(exc)


def http_get(url: str, timeout: float = 2.0, headers: dict | None = None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return True, resp.status, body
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return False, exc.code, body
    except Exception as exc:
        return False, None, str(exc)


def parse_metrics(metrics_text: str, names: list[str]):
    wanted = set(names)
    parsed: dict[str, float | str] = {}
    for raw in metrics_text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        metric, value = parts[0], parts[1]
        if metric not in wanted:
            continue
        try:
            parsed[metric] = float(value)
        except ValueError:
            parsed[metric] = value
    return parsed


def read_latest_json(rel_path: str):
    full_path = (root_dir / rel_path).resolve()
    if not full_path.exists():
        return {"present": False, "path": str(full_path), "payload": None}
    try:
        with open(full_path, "r", encoding="utf-8") as f:
            payload = json.load(f)
        return {"present": True, "path": str(full_path), "payload": payload}
    except Exception as exc:
        return {
            "present": True,
            "path": str(full_path),
            "payload": None,
            "error": str(exc),
        }


def kafka_status_via_rpk():
    cmd = [
        "docker",
        "compose",
        "-f",
        compose_file,
        "exec",
        "-T",
        "redpanda",
        "rpk",
        "cluster",
        "info",
    ]
    try:
        proc = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except Exception as exc:
        return {
            "up": False,
            "method": "rpk",
            "error": str(exc),
        }

    if proc.returncode == 0:
        return {
            "up": True,
            "method": "rpk",
            "details": (proc.stdout or "").strip().splitlines(),
        }

    return {
        "up": False,
        "method": "rpk",
        "error": (proc.stderr or proc.stdout or "rpk failed").strip(),
    }


core_up, core_err = tcp_check(core_host, core_port)

edge_ready_ok, edge_ready_status, edge_ready_body = http_get(f"{edge_url}/readyz")
edge_metrics_ok, edge_metrics_status, edge_metrics_body = http_get(f"{edge_url}/metrics")
edge_reachable = bool(edge_ready_ok or edge_metrics_ok)
edge_ws_metrics = (
    parse_metrics(
        edge_metrics_body if edge_metrics_ok else "",
        [
            "ws_active_conns",
            "ws_send_queue_p99",
            "ws_dropped_msgs",
            "ws_resume_gaps",
            "ws_slow_closes",
            "ws_policy_closes",
            "ws_command_rate_limit_closes",
            "ws_connection_rejects",
        ],
    )
    if edge_metrics_ok
    else {}
)

ledger_ready_ok, ledger_ready_status, ledger_ready_body = http_get(f"{ledger_url}/readyz")
recon_headers = {}
if ledger_admin_token:
    recon_headers["X-Admin-Token"] = ledger_admin_token
recon_ok, recon_status, recon_body = http_get(
    urljoin(f"{ledger_url}/", "v1/admin/reconciliation/status"),
    headers=recon_headers,
)
reconciliation = None
if recon_ok:
    try:
        reconciliation = json.loads(recon_body)
    except json.JSONDecodeError:
        reconciliation = {"raw": recon_body}
else:
    reconciliation = {"error": recon_body, "http_status": recon_status}

kafka_status = kafka_status_via_rpk()
if not kafka_status.get("up"):
    broker_host, _, broker_port_raw = kafka_broker.rpartition(":")
    broker_port = int(broker_port_raw) if broker_port_raw.isdigit() else 29092
    broker_host = broker_host or kafka_broker
    kafka_tcp_ok, kafka_tcp_err = tcp_check(broker_host, broker_port)
    kafka_status = {
        "up": kafka_tcp_ok,
        "method": "tcp",
        "broker": kafka_broker,
        "error": None if kafka_tcp_ok else kafka_tcp_err,
    }

controls_latest = read_latest_json("build/controls/controls-check-latest.json")
controls_freshness_latest = read_latest_json("build/controls/prove-controls-freshness-latest.json")
determinism_latest = read_latest_json("build/determinism/prove-determinism-latest.json")
audit_chain_latest = read_latest_json("build/audit/verify-audit-chain-latest.json")
change_audit_chain_latest = read_latest_json("build/change-audit/verify-change-audit-chain-latest.json")
pii_scan_latest = read_latest_json("build/security/pii-log-scan-latest.json")
safety_budget_latest = read_latest_json("build/safety/safety-budget-latest.json")
budget_freshness_latest = read_latest_json("build/safety/prove-budget-freshness-latest.json")
policy_smoke_latest = read_latest_json("build/policy-smoke/policy-smoke-latest.json")
policy_tamper_latest = read_latest_json("build/policy/prove-policy-tamper-latest.json")
network_partition_latest = read_latest_json("build/chaos/network-partition-latest.json")
redpanda_bounce_latest = read_latest_json("build/chaos/redpanda-broker-bounce-latest.json")
adversarial_latest = read_latest_json("build/adversarial/adversarial-tests-latest.json")

ok = bool(core_up and edge_reachable and ledger_ready_ok and kafka_status.get("up"))

report = {
    "generated_at_utc": now_utc(),
    "ok": ok,
    "checks": {
        "core": {
            "up": core_up,
            "host": core_host,
            "port": core_port,
            "error": core_err,
        },
        "edge": {
            "reachable": edge_reachable,
            "ready": edge_ready_ok,
            "ready_http_status": edge_ready_status,
            "ready_body": edge_ready_body,
            "metrics_http_status": edge_metrics_status,
            "ws_metrics": edge_ws_metrics,
        },
        "ledger": {
            "ready": ledger_ready_ok,
            "ready_http_status": ledger_ready_status,
            "ready_body": ledger_ready_body,
            "reconciliation": reconciliation,
        },
        "kafka": kafka_status,
        "compliance": {
            "controls": {
                "present": controls_latest.get("present", False),
                "path": controls_latest.get("path"),
                "ok": (controls_latest.get("payload") or {}).get("ok"),
                "failed_enforced_count": (controls_latest.get("payload") or {}).get(
                    "failed_enforced_count"
                ),
                "failed_enforced_stale_count": (controls_latest.get("payload") or {}).get(
                    "failed_enforced_stale_count"
                ),
                "advisory_missing_count": (controls_latest.get("payload") or {}).get(
                    "advisory_missing_count"
                ),
                "advisory_stale_count": (controls_latest.get("payload") or {}).get(
                    "advisory_stale_count"
                ),
                "error": controls_latest.get("error"),
            },
            "audit_chain": {
                "present": audit_chain_latest.get("present", False),
                "path": audit_chain_latest.get("path"),
                "ok": (audit_chain_latest.get("payload") or {}).get("ok"),
                "mode": (audit_chain_latest.get("payload") or {}).get("mode"),
                "head_hash": (audit_chain_latest.get("payload") or {}).get("head_hash"),
                "entry_count": (audit_chain_latest.get("payload") or {}).get("entry_count"),
                "error": audit_chain_latest.get("error"),
            },
            "change_audit_chain": {
                "present": change_audit_chain_latest.get("present", False),
                "path": change_audit_chain_latest.get("path"),
                "ok": (change_audit_chain_latest.get("payload") or {}).get("ok"),
                "mode": (change_audit_chain_latest.get("payload") or {}).get("mode"),
                "head_hash": (change_audit_chain_latest.get("payload") or {}).get("head_hash"),
                "entry_count": (change_audit_chain_latest.get("payload") or {}).get("entry_count"),
                "error": change_audit_chain_latest.get("error"),
            },
            "pii_log_scan": {
                "present": pii_scan_latest.get("present", False),
                "path": pii_scan_latest.get("path"),
                "ok": (pii_scan_latest.get("payload") or {}).get("ok"),
                "hit_count": (pii_scan_latest.get("payload") or {}).get("hit_count"),
                "files_scanned": (pii_scan_latest.get("payload") or {}).get("files_scanned"),
                "error": pii_scan_latest.get("error"),
            },
            "policy_smoke": {
                "present": policy_smoke_latest.get("present", False),
                "path": policy_smoke_latest.get("path"),
                "ok": (policy_smoke_latest.get("payload") or {}).get("ok"),
                "policy_file": (policy_smoke_latest.get("payload") or {}).get("policy_file"),
                "signature_file": (policy_smoke_latest.get("payload") or {}).get("signature_file"),
                "error": policy_smoke_latest.get("error"),
            },
            "policy_tamper": {
                "present": policy_tamper_latest.get("present", False),
                "path": policy_tamper_latest.get("path"),
                "ok": (policy_tamper_latest.get("payload") or {}).get("ok"),
                "tamper_detected": (policy_tamper_latest.get("payload") or {}).get("tamper_detected"),
                "error": policy_tamper_latest.get("error"),
            },
            "chaos_network_partition": {
                "present": network_partition_latest.get("present", False),
                "path": network_partition_latest.get("path"),
                "ok": (network_partition_latest.get("payload") or {}).get("ok"),
                "applied_isolation_method": (
                    (network_partition_latest.get("payload") or {}).get("scenario", {}) or {}
                ).get("applied_isolation_method"),
                "during_partition_broker_reachable": (
                    (network_partition_latest.get("payload") or {}).get("connectivity", {}) or {}
                ).get("during_partition_broker_reachable"),
                "after_recovery_broker_reachable": (
                    (network_partition_latest.get("payload") or {}).get("connectivity", {}) or {}
                ).get("after_recovery_broker_reachable"),
                "error": network_partition_latest.get("error"),
            },
            "chaos_redpanda_bounce": {
                "present": redpanda_bounce_latest.get("present", False),
                "path": redpanda_bounce_latest.get("path"),
                "ok": (redpanda_bounce_latest.get("payload") or {}).get("ok"),
                "during_stop_broker_reachable": (
                    (redpanda_bounce_latest.get("payload") or {}).get("connectivity", {}) or {}
                ).get("during_stop_broker_reachable"),
                "after_restart_broker_reachable": (
                    (redpanda_bounce_latest.get("payload") or {}).get("connectivity", {}) or {}
                ).get("after_restart_broker_reachable"),
                "post_restart_consume_ok": (
                    (redpanda_bounce_latest.get("payload") or {}).get("connectivity", {}) or {}
                ).get("post_restart_consume_ok"),
                "error": redpanda_bounce_latest.get("error"),
            },
            "safety_budget": {
                "present": safety_budget_latest.get("present", False),
                "path": safety_budget_latest.get("path"),
                "ok": (safety_budget_latest.get("payload") or {}).get("ok"),
                "violations_count": len((safety_budget_latest.get("payload") or {}).get("violations", []) or []),
                "freshness_default_max_age_seconds": (safety_budget_latest.get("payload") or {}).get("freshness_default_max_age_seconds"),
                "error": safety_budget_latest.get("error"),
            },
            "adversarial_tests": {
                "present": adversarial_latest.get("present", False),
                "path": adversarial_latest.get("path"),
                "ok": (adversarial_latest.get("payload") or {}).get("ok"),
                "failed_step_count": len(
                    [
                        step
                        for step in ((adversarial_latest.get("payload") or {}).get("steps", []) or [])
                        if isinstance(step, dict) and step.get("status") == "fail"
                    ]
                ),
                "exactly_once_status": next(
                    (
                        step.get("status")
                        for step in ((adversarial_latest.get("payload") or {}).get("steps", []) or [])
                        if isinstance(step, dict) and step.get("name") == "exactly_once_stress"
                    ),
                    None,
                ),
                "error": adversarial_latest.get("error"),
            },
            "proofs": {
                "determinism": {
                    "present": determinism_latest.get("present", False),
                    "path": determinism_latest.get("path"),
                    "ok": (determinism_latest.get("payload") or {}).get("ok"),
                    "executed_runs": (determinism_latest.get("payload") or {}).get("executed_runs"),
                    "distinct_hashes_count": len(((determinism_latest.get("payload") or {}).get("distinct_hashes", []) or [])),
                    "error": determinism_latest.get("error"),
                },
                "controls_freshness": {
                    "present": controls_freshness_latest.get("present", False),
                    "path": controls_freshness_latest.get("path"),
                    "ok": (controls_freshness_latest.get("payload") or {}).get("ok"),
                    "error": controls_freshness_latest.get("error"),
                },
                "budget_freshness": {
                    "present": budget_freshness_latest.get("present", False),
                    "path": budget_freshness_latest.get("path"),
                    "ok": (budget_freshness_latest.get("payload") or {}).get("ok"),
                    "error": budget_freshness_latest.get("error"),
                },
            },
        },
    },
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")
PY

cp "$REPORT_FILE" "$LATEST_FILE"

OK="$("$PYTHON_BIN" - "$REPORT_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "system_status_report=$REPORT_FILE"
echo "system_status_latest=$LATEST_FILE"
echo "system_status_ok=$OK"

if [[ "$STRICT" == "true" && "$OK" != "true" ]]; then
  exit 1
fi
