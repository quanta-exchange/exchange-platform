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
compliance_latest = read_latest_json("build/compliance/compliance-evidence-latest.json")
mapping_integrity_latest = read_latest_json(
    "build/compliance/prove-mapping-integrity-latest.json"
)
mapping_coverage_latest = read_latest_json(
    "build/compliance/prove-mapping-coverage-latest.json"
)
controls_freshness_latest = read_latest_json("build/controls/prove-controls-freshness-latest.json")
determinism_latest = read_latest_json("build/determinism/prove-determinism-latest.json")
idempotency_scope_latest = read_latest_json("build/idempotency/prove-idempotency-latest.json")
idempotency_key_format_latest = read_latest_json(
    "build/idempotency/prove-idempotency-key-format-latest.json"
)
latch_approval_latest = read_latest_json("build/latch/prove-latch-approval-latest.json")
exactly_once_million_latest = read_latest_json(
    "build/exactly-once/prove-exactly-once-million-latest.json"
)
audit_chain_latest = read_latest_json("build/audit/verify-audit-chain-latest.json")
change_audit_chain_latest = read_latest_json("build/change-audit/verify-change-audit-chain-latest.json")
pii_scan_latest = read_latest_json("build/security/pii-log-scan-latest.json")
safety_budget_latest = read_latest_json("build/safety/safety-budget-latest.json")
budget_freshness_latest = read_latest_json("build/safety/prove-budget-freshness-latest.json")
proof_health_latest = read_latest_json("build/metrics/proof-health-latest.json")
mapping_coverage_metrics_latest = read_latest_json("build/metrics/mapping-coverage-latest.json")
release_gate_latest = read_latest_json("build/release-gate/release-gate-latest.json")
release_gate_fallback_smoke_latest = read_latest_json(
    "build/release-gate-smoke/release-gate-fallback-smoke-latest.json"
)
release_gate_context_proof_latest = read_latest_json(
    "build/release-gate/prove-release-gate-context-latest.json"
)
policy_smoke_latest = read_latest_json("build/policy-smoke/policy-smoke-latest.json")
policy_tamper_latest = read_latest_json("build/policy/prove-policy-tamper-latest.json")
network_partition_latest = read_latest_json("build/chaos/network-partition-latest.json")
redpanda_bounce_latest = read_latest_json("build/chaos/redpanda-broker-bounce-latest.json")
adversarial_latest = read_latest_json("build/adversarial/adversarial-tests-latest.json")
policy_signature_runbook_latest = read_latest_json("build/runbooks/policy-signature-latest.json")
policy_tamper_runbook_latest = read_latest_json("build/runbooks/policy-tamper-latest.json")
network_partition_runbook_latest = read_latest_json("build/runbooks/network-partition-latest.json")
redpanda_bounce_runbook_latest = read_latest_json(
    "build/runbooks/redpanda-broker-bounce-latest.json"
)
adversarial_runbook_latest = read_latest_json("build/runbooks/adversarial-reliability-latest.json")
exactly_once_runbook_latest = read_latest_json("build/runbooks/exactly-once-million-latest.json")
mapping_integrity_runbook_latest = read_latest_json("build/runbooks/mapping-integrity-latest.json")
mapping_coverage_runbook_latest = read_latest_json("build/runbooks/mapping-coverage-latest.json")
idempotency_latch_runbook_latest = read_latest_json("build/runbooks/idempotency-latch-latest.json")
idempotency_key_format_runbook_latest = read_latest_json(
    "build/runbooks/idempotency-key-format-latest.json"
)
proof_health_runbook_latest = read_latest_json("build/runbooks/proof-health-latest.json")

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
            "evidence_pack": {
                "present": compliance_latest.get("present", False),
                "path": compliance_latest.get("path"),
                "ok": (compliance_latest.get("payload") or {}).get("ok"),
                "mapping_count": (compliance_latest.get("payload") or {}).get("mapping_count"),
                "missing_controls_count": (compliance_latest.get("payload") or {}).get(
                    "missing_controls_count"
                ),
                "duplicate_mapping_ids_count": (compliance_latest.get("payload") or {}).get(
                    "duplicate_mapping_ids_count"
                ),
                "unmapped_controls_count": (compliance_latest.get("payload") or {}).get(
                    "unmapped_controls_count"
                ),
                "unmapped_enforced_controls_count": (compliance_latest.get("payload") or {}).get(
                    "unmapped_enforced_controls_count"
                ),
                "mapping_coverage_ratio": (compliance_latest.get("payload") or {}).get(
                    "mapping_coverage_ratio"
                ),
                "error": compliance_latest.get("error"),
            },
            "mapping_coverage_proof": {
                "present": mapping_coverage_latest.get("present", False),
                "path": mapping_coverage_latest.get("path"),
                "ok": (mapping_coverage_latest.get("payload") or {}).get("ok"),
                "require_full_coverage": (mapping_coverage_latest.get("payload") or {}).get(
                    "require_full_coverage"
                ),
                "mapping_coverage_ratio": (mapping_coverage_latest.get("payload") or {}).get(
                    "mapping_coverage_ratio"
                ),
                "missing_controls_count": (mapping_coverage_latest.get("payload") or {}).get(
                    "missing_controls_count"
                ),
                "unmapped_controls_count": (mapping_coverage_latest.get("payload") or {}).get(
                    "unmapped_controls_count"
                ),
                "unmapped_enforced_controls_count": (
                    mapping_coverage_latest.get("payload") or {}
                ).get("unmapped_enforced_controls_count"),
                "duplicate_control_ids_count": (
                    mapping_coverage_latest.get("payload") or {}
                ).get("duplicate_control_ids_count"),
                "duplicate_mapping_ids_count": (
                    mapping_coverage_latest.get("payload") or {}
                ).get("duplicate_mapping_ids_count"),
                "error": mapping_coverage_latest.get("error"),
            },
            "mapping_coverage_metrics": {
                "present": mapping_coverage_metrics_latest.get("present", False),
                "path": mapping_coverage_metrics_latest.get("path"),
                "ok": (mapping_coverage_metrics_latest.get("payload") or {}).get("ok"),
                "health_ok": (mapping_coverage_metrics_latest.get("payload") or {}).get(
                    "health_ok"
                ),
                "export_ok": (mapping_coverage_metrics_latest.get("payload") or {}).get(
                    "export_ok"
                ),
                "mapping_coverage_ratio": (
                    mapping_coverage_metrics_latest.get("payload") or {}
                ).get("mapping_coverage_ratio"),
                "missing_controls_count": (
                    mapping_coverage_metrics_latest.get("payload") or {}
                ).get("missing_controls_count"),
                "unmapped_enforced_controls_count": (
                    mapping_coverage_metrics_latest.get("payload") or {}
                ).get("unmapped_enforced_controls_count"),
                "duplicate_control_ids_count": (
                    mapping_coverage_metrics_latest.get("payload") or {}
                ).get("duplicate_control_ids_count"),
                "duplicate_mapping_ids_count": (
                    mapping_coverage_metrics_latest.get("payload") or {}
                ).get("duplicate_mapping_ids_count"),
                "runbook_recommended_action": (
                    mapping_coverage_metrics_latest.get("payload") or {}
                ).get("runbook_recommended_action"),
                "error": mapping_coverage_metrics_latest.get("error"),
            },
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
            "release_gate": {
                "present": release_gate_latest.get("present", False),
                "path": release_gate_latest.get("path"),
                "ok": (release_gate_latest.get("payload") or {}).get("ok"),
                "runbook_context_backfill_ok": (
                    release_gate_latest.get("payload") or {}
                ).get("runbook_context_backfill_ok"),
                "runbook_context_missing_count": len(
                    (release_gate_latest.get("payload") or {}).get(
                        "runbook_context_missing", []
                    )
                    or []
                ),
                "require_runbook_context": (
                    release_gate_latest.get("payload") or {}
                ).get("require_runbook_context"),
                "error": release_gate_latest.get("error"),
            },
            "release_gate_fallback_smoke": {
                "present": release_gate_fallback_smoke_latest.get("present", False),
                "path": release_gate_fallback_smoke_latest.get("path"),
                "ok": (release_gate_fallback_smoke_latest.get("payload") or {}).get("ok"),
                "used_release_gate_embedded_check": (
                    release_gate_fallback_smoke_latest.get("payload") or {}
                ).get("used_release_gate_embedded_check"),
                "release_gate_runbook_context_backfill_ok": (
                    release_gate_fallback_smoke_latest.get("payload") or {}
                ).get("release_gate_runbook_context_backfill_ok"),
                "missing_fields_count": len(
                    (release_gate_fallback_smoke_latest.get("payload") or {}).get(
                        "missing_fields", []
                    )
                    or []
                ),
                "error": release_gate_fallback_smoke_latest.get("error"),
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
            "runbooks": {
                "policy_signature": {
                    "present": policy_signature_runbook_latest.get("present", False),
                    "path": policy_signature_runbook_latest.get("path"),
                    "runbook_ok": (
                        policy_signature_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        policy_signature_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "policy_ok": (
                        policy_signature_runbook_latest.get("payload") or {}
                    ).get("policy_ok"),
                    "policy_exit_code": (
                        policy_signature_runbook_latest.get("payload") or {}
                    ).get("policy_exit_code"),
                    "recommended_action": (
                        policy_signature_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": policy_signature_runbook_latest.get("error"),
                },
                "policy_tamper": {
                    "present": policy_tamper_runbook_latest.get("present", False),
                    "path": policy_tamper_runbook_latest.get("path"),
                    "runbook_ok": (
                        policy_tamper_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        policy_tamper_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "policy_tamper_ok": (
                        policy_tamper_runbook_latest.get("payload") or {}
                    ).get("policy_tamper_ok"),
                    "tamper_detected": (
                        policy_tamper_runbook_latest.get("payload") or {}
                    ).get("tamper_detected"),
                    "policy_tamper_exit_code": (
                        policy_tamper_runbook_latest.get("payload") or {}
                    ).get("policy_tamper_exit_code"),
                    "recommended_action": (
                        policy_tamper_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": policy_tamper_runbook_latest.get("error"),
                },
                "network_partition": {
                    "present": network_partition_runbook_latest.get("present", False),
                    "path": network_partition_runbook_latest.get("path"),
                    "runbook_ok": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "network_partition_ok": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("network_partition_ok"),
                    "applied_isolation_method": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("applied_isolation_method"),
                    "during_partition_broker_reachable": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("during_partition_broker_reachable"),
                    "network_partition_exit_code": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("network_partition_exit_code"),
                    "recommended_action": (
                        network_partition_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": network_partition_runbook_latest.get("error"),
                },
                "redpanda_broker_bounce": {
                    "present": redpanda_bounce_runbook_latest.get("present", False),
                    "path": redpanda_bounce_runbook_latest.get("path"),
                    "runbook_ok": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "redpanda_broker_bounce_ok": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("redpanda_broker_bounce_ok"),
                    "during_stop_broker_reachable": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("during_stop_broker_reachable"),
                    "after_restart_broker_reachable": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("after_restart_broker_reachable"),
                    "post_restart_consume_ok": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("post_restart_consume_ok"),
                    "redpanda_broker_bounce_exit_code": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("redpanda_broker_bounce_exit_code"),
                    "recommended_action": (
                        redpanda_bounce_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": redpanda_bounce_runbook_latest.get("error"),
                },
                "adversarial_reliability": {
                    "present": adversarial_runbook_latest.get("present", False),
                    "path": adversarial_runbook_latest.get("path"),
                    "runbook_ok": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "adversarial_ok": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("adversarial_ok"),
                    "failed_step_count": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("failed_step_count"),
                    "skipped_step_count": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("skipped_step_count"),
                    "exactly_once_status": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("exactly_once_status"),
                    "adversarial_exit_code": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("adversarial_exit_code"),
                    "recommended_action": (
                        adversarial_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": adversarial_runbook_latest.get("error"),
                },
                "exactly_once_million": {
                    "present": exactly_once_runbook_latest.get("present", False),
                    "path": exactly_once_runbook_latest.get("path"),
                    "runbook_ok": (
                        exactly_once_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        exactly_once_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "proof_ok": (exactly_once_runbook_latest.get("payload") or {}).get(
                        "proof_ok"
                    ),
                    "proof_repeats": (exactly_once_runbook_latest.get("payload") or {}).get(
                        "proof_repeats"
                    ),
                    "proof_concurrency": (
                        exactly_once_runbook_latest.get("payload") or {}
                    ).get("proof_concurrency"),
                    "recommended_action": (
                        exactly_once_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": exactly_once_runbook_latest.get("error"),
                },
                "mapping_integrity": {
                    "present": mapping_integrity_runbook_latest.get("present", False),
                    "path": mapping_integrity_runbook_latest.get("path"),
                    "runbook_ok": (
                        mapping_integrity_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        mapping_integrity_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "proof_ok": (mapping_integrity_runbook_latest.get("payload") or {}).get(
                        "proof_ok"
                    ),
                    "duplicate_probe_exit_code": (
                        mapping_integrity_runbook_latest.get("payload") or {}
                    ).get("duplicate_probe_exit_code"),
                    "duplicate_mapping_ids_count": (
                        mapping_integrity_runbook_latest.get("payload") or {}
                    ).get("duplicate_mapping_ids_count"),
                    "baseline_probe_exit_code": (
                        mapping_integrity_runbook_latest.get("payload") or {}
                    ).get("baseline_probe_exit_code"),
                    "recommended_action": (
                        mapping_integrity_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": mapping_integrity_runbook_latest.get("error"),
                },
                "mapping_coverage": {
                    "present": mapping_coverage_runbook_latest.get("present", False),
                    "path": mapping_coverage_runbook_latest.get("path"),
                    "runbook_ok": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "proof_ok": (mapping_coverage_runbook_latest.get("payload") or {}).get(
                        "proof_ok"
                    ),
                    "baseline_ok": (mapping_coverage_runbook_latest.get("payload") or {}).get(
                        "baseline_ok"
                    ),
                    "strict_probe_exit_code": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("strict_probe_exit_code"),
                    "strict_unmapped_controls_count": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("strict_unmapped_controls_count"),
                    "partial_probe_exit_code": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("partial_probe_exit_code"),
                    "partial_unmapped_controls_count": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("partial_unmapped_controls_count"),
                    "partial_unmapped_enforced_controls_count": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("partial_unmapped_enforced_controls_count"),
                    "recommended_action": (
                        mapping_coverage_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": mapping_coverage_runbook_latest.get("error"),
                },
                "idempotency_latch": {
                    "present": idempotency_latch_runbook_latest.get("present", False),
                    "path": idempotency_latch_runbook_latest.get("path"),
                    "runbook_ok": (
                        idempotency_latch_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        idempotency_latch_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "idempotency_ok": (
                        idempotency_latch_runbook_latest.get("payload") or {}
                    ).get("idempotency_ok"),
                    "latch_ok": (idempotency_latch_runbook_latest.get("payload") or {}).get(
                        "latch_ok"
                    ),
                    "idempotency_passed": (
                        idempotency_latch_runbook_latest.get("payload") or {}
                    ).get("idempotency_passed"),
                    "latch_missing_tests_count": (
                        idempotency_latch_runbook_latest.get("payload") or {}
                    ).get("latch_missing_tests_count"),
                    "recommended_action": (
                        idempotency_latch_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": idempotency_latch_runbook_latest.get("error"),
                },
                "idempotency_key_format": {
                    "present": idempotency_key_format_runbook_latest.get("present", False),
                    "path": idempotency_key_format_runbook_latest.get("path"),
                    "runbook_ok": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "proof_ok": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("proof_ok"),
                    "requested_tests_count": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("requested_tests_count"),
                    "missing_tests_count": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("missing_tests_count"),
                    "failed_tests_count": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("failed_tests_count"),
                    "recommended_action": (
                        idempotency_key_format_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": idempotency_key_format_runbook_latest.get("error"),
                },
                "proof_health": {
                    "present": proof_health_runbook_latest.get("present", False),
                    "path": proof_health_runbook_latest.get("path"),
                    "runbook_ok": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("runbook_ok"),
                    "budget_ok": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("budget_ok"),
                    "proof_health_ok": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("proof_health_ok"),
                    "tracked_count": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("tracked_count"),
                    "present_count": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("present_count"),
                    "missing_count": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("missing_count"),
                    "failing_count": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("failing_count"),
                    "recommended_action": (
                        proof_health_runbook_latest.get("payload") or {}
                    ).get("recommended_action"),
                    "error": proof_health_runbook_latest.get("error"),
                }
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
                "idempotency_scope": {
                    "present": idempotency_scope_latest.get("present", False),
                    "path": idempotency_scope_latest.get("path"),
                    "ok": (idempotency_scope_latest.get("payload") or {}).get("ok"),
                    "passed": (idempotency_scope_latest.get("payload") or {}).get("passed"),
                    "failed": (idempotency_scope_latest.get("payload") or {}).get("failed"),
                    "cargo_exit_code": (idempotency_scope_latest.get("payload") or {}).get("cargo_exit_code"),
                    "error": idempotency_scope_latest.get("error"),
                },
                "idempotency_key_format": {
                    "present": idempotency_key_format_latest.get("present", False),
                    "path": idempotency_key_format_latest.get("path"),
                    "ok": (idempotency_key_format_latest.get("payload") or {}).get("ok"),
                    "requested_tests_count": len(
                        ((idempotency_key_format_latest.get("payload") or {}).get("requested_tests", []) or [])
                    ),
                    "missing_tests_count": len(
                        ((idempotency_key_format_latest.get("payload") or {}).get("missing_tests", []) or [])
                    ),
                    "failed_tests_count": len(
                        ((idempotency_key_format_latest.get("payload") or {}).get("failed_tests", []) or [])
                    ),
                    "go_exit_code": (idempotency_key_format_latest.get("payload") or {}).get("go_exit_code"),
                    "error": idempotency_key_format_latest.get("error"),
                },
                "latch_approval": {
                    "present": latch_approval_latest.get("present", False),
                    "path": latch_approval_latest.get("path"),
                    "ok": (latch_approval_latest.get("payload") or {}).get("ok"),
                    "requested_tests_count": len(
                        ((latch_approval_latest.get("payload") or {}).get("requested_tests", []) or [])
                    ),
                    "missing_tests_count": len(
                        ((latch_approval_latest.get("payload") or {}).get("missing_tests", []) or [])
                    ),
                    "failed_tests_count": len(
                        ((latch_approval_latest.get("payload") or {}).get("failed_tests", []) or [])
                    ),
                    "gradle_exit_code": (latch_approval_latest.get("payload") or {}).get("gradle_exit_code"),
                    "error": latch_approval_latest.get("error"),
                },
                "exactly_once_million": {
                    "present": exactly_once_million_latest.get("present", False),
                    "path": exactly_once_million_latest.get("path"),
                    "ok": (exactly_once_million_latest.get("payload") or {}).get("ok"),
                    "repeats": (exactly_once_million_latest.get("payload") or {}).get("repeats"),
                    "concurrency": (exactly_once_million_latest.get("payload") or {}).get(
                        "concurrency"
                    ),
                    "runner_exit_code": (exactly_once_million_latest.get("payload") or {}).get(
                        "runner_exit_code"
                    ),
                    "error": exactly_once_million_latest.get("error"),
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
                "release_gate_context": {
                    "present": release_gate_context_proof_latest.get("present", False),
                    "path": release_gate_context_proof_latest.get("path"),
                    "ok": (release_gate_context_proof_latest.get("payload") or {}).get(
                        "ok"
                    ),
                    "expect_require_runbook_context": (
                        release_gate_context_proof_latest.get("payload") or {}
                    ).get("expect_require_runbook_context"),
                    "failed_checks_count": len(
                        (
                            release_gate_context_proof_latest.get("payload") or {}
                        ).get("failed_checks", [])
                        or []
                    ),
                    "release_gate_present": (
                        (release_gate_context_proof_latest.get("payload") or {}).get(
                            "release_gate", {}
                        )
                        or {}
                    ).get("present"),
                    "release_gate_runbook_context_backfill_ok": (
                        (release_gate_context_proof_latest.get("payload") or {}).get(
                            "release_gate", {}
                        )
                        or {}
                    ).get("runbook_context_backfill_ok"),
                    "release_gate_runbook_context_missing_count": (
                        (release_gate_context_proof_latest.get("payload") or {}).get(
                            "release_gate", {}
                        )
                        or {}
                    ).get("runbook_context_missing_count"),
                    "fallback_smoke_present": (
                        (release_gate_context_proof_latest.get("payload") or {}).get(
                            "fallback_smoke", {}
                        )
                        or {}
                    ).get("present"),
                    "fallback_smoke_missing_fields_count": (
                        (release_gate_context_proof_latest.get("payload") or {}).get(
                            "fallback_smoke", {}
                        )
                        or {}
                    ).get("missing_fields_count"),
                    "error": release_gate_context_proof_latest.get("error"),
                },
                "proof_health": {
                    "present": proof_health_latest.get("present", False),
                    "path": proof_health_latest.get("path"),
                    "ok": (proof_health_latest.get("payload") or {}).get("ok"),
                    "health_ok": (proof_health_latest.get("payload") or {}).get(
                        "health_ok"
                    ),
                    "export_ok": (proof_health_latest.get("payload") or {}).get(
                        "export_ok"
                    ),
                    "tracked_count": (proof_health_latest.get("payload") or {}).get(
                        "tracked_count"
                    ),
                    "present_count": (proof_health_latest.get("payload") or {}).get(
                        "present_count"
                    ),
                    "missing_count": (proof_health_latest.get("payload") or {}).get(
                        "missing_count"
                    ),
                    "failing_count": (proof_health_latest.get("payload") or {}).get(
                        "failing_count"
                    ),
                    "error": proof_health_latest.get("error"),
                },
                "mapping_integrity": {
                    "present": mapping_integrity_latest.get("present", False),
                    "path": mapping_integrity_latest.get("path"),
                    "ok": (mapping_integrity_latest.get("payload") or {}).get("ok"),
                    "error": mapping_integrity_latest.get("error"),
                },
                "mapping_coverage": {
                    "present": mapping_coverage_latest.get("present", False),
                    "path": mapping_coverage_latest.get("path"),
                    "ok": (mapping_coverage_latest.get("payload") or {}).get("ok"),
                    "mapping_coverage_ratio": (
                        mapping_coverage_latest.get("payload") or {}
                    ).get("mapping_coverage_ratio"),
                    "missing_controls_count": (
                        mapping_coverage_latest.get("payload") or {}
                    ).get("missing_controls_count"),
                    "unmapped_controls_count": (
                        mapping_coverage_latest.get("payload") or {}
                    ).get("unmapped_controls_count"),
                    "unmapped_enforced_controls_count": (
                        mapping_coverage_latest.get("payload") or {}
                    ).get("unmapped_enforced_controls_count"),
                    "duplicate_control_ids_count": (
                        mapping_coverage_latest.get("payload") or {}
                    ).get("duplicate_control_ids_count"),
                    "duplicate_mapping_ids_count": (
                        mapping_coverage_latest.get("payload") or {}
                    ).get("duplicate_mapping_ids_count"),
                    "error": mapping_coverage_latest.get("error"),
                },
                "mapping_coverage_metrics": {
                    "present": mapping_coverage_metrics_latest.get("present", False),
                    "path": mapping_coverage_metrics_latest.get("path"),
                    "ok": (mapping_coverage_metrics_latest.get("payload") or {}).get("ok"),
                    "health_ok": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("health_ok"),
                    "export_ok": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("export_ok"),
                    "mapping_coverage_ratio": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("mapping_coverage_ratio"),
                    "missing_controls_count": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("missing_controls_count"),
                    "unmapped_enforced_controls_count": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("unmapped_enforced_controls_count"),
                    "duplicate_control_ids_count": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("duplicate_control_ids_count"),
                    "duplicate_mapping_ids_count": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("duplicate_mapping_ids_count"),
                    "runbook_recommended_action": (
                        mapping_coverage_metrics_latest.get("payload") or {}
                    ).get("runbook_recommended_action"),
                    "error": mapping_coverage_metrics_latest.get("error"),
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
