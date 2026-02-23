#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/assurance"
ALLOW_MISSING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
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
PACK_DIR="$OUT_DIR/$TS_ID"
PACK_JSON="$PACK_DIR/assurance-pack.json"
PACK_MD="$PACK_DIR/assurance-pack.md"
mkdir -p "$PACK_DIR"

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

python3 - "$ROOT_DIR" "$PACK_JSON" "$PACK_MD" "$TS" "$COMMIT" "$BRANCH" <<'PY'
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
pack_json = pathlib.Path(sys.argv[2]).resolve()
pack_md = pathlib.Path(sys.argv[3]).resolve()
generated_at = sys.argv[4]
git_commit = sys.argv[5]
git_branch = sys.argv[6]

def rel(path: pathlib.Path | None) -> str | None:
    if path is None:
        return None
    return str(path.resolve().relative_to(root))

def newest(candidates):
    existing = [p for p in candidates if p.exists()]
    if not existing:
        return None
    return max(existing, key=lambda p: p.stat().st_mtime)

safety_case_manifest = newest(
    list(root.glob("build/safety-case/*/manifest.json"))
    + [root / "build/safety-case/manifest.json"]
)
safety_case_artifact = newest(root.glob("build/safety-case/safety-case-*.tar.gz"))
safety_case_sha = (
    pathlib.Path(str(safety_case_artifact) + ".sha256")
    if safety_case_artifact and pathlib.Path(str(safety_case_artifact) + ".sha256").exists()
    else None
)
startup_guardrails_runbook = newest(root.glob("build/runbooks/startup-guardrails-*/startup-guardrails.log"))

evidence = [
    {"id": "load_smoke", "path": pathlib.Path("build/load/load-smoke.json"), "required": True},
    {"id": "load_all", "path": pathlib.Path("build/load/load-all-latest.json"), "required": False},
    {"id": "startup_guardrails_runbook", "path": pathlib.Path(rel(startup_guardrails_runbook)) if startup_guardrails_runbook else None, "required": False},
    {"id": "verify_audit_chain", "path": pathlib.Path("build/audit/verify-audit-chain-latest.json"), "required": False},
    {"id": "pii_log_scan", "path": pathlib.Path("build/security/pii-log-scan-latest.json"), "required": False},
    {"id": "dr_rehearsal", "path": pathlib.Path("build/dr/dr-report.json"), "required": True},
    {"id": "invariants", "path": pathlib.Path("build/invariants/ledger-invariants.json"), "required": True},
    {"id": "invariants_summary", "path": pathlib.Path("build/invariants/invariants-summary.json"), "required": False},
    {"id": "core_invariants", "path": pathlib.Path("build/invariants/core-invariants.json"), "required": False},
    {"id": "exactly_once", "path": pathlib.Path("build/exactly-once/exactly-once-stress.json"), "required": False},
    {"id": "reconciliation_smoke", "path": pathlib.Path("build/reconciliation/smoke-reconciliation-safety.json"), "required": False},
    {"id": "chaos_replay", "path": pathlib.Path("build/chaos/chaos-replay.json"), "required": False},
    {"id": "redpanda_bounce", "path": pathlib.Path("build/chaos/redpanda-broker-bounce.json"), "required": False},
    {"id": "determinism", "path": pathlib.Path("build/determinism/prove-determinism-latest.json"), "required": False},
    {"id": "idempotency_scope", "path": pathlib.Path("build/idempotency/prove-idempotency-latest.json"), "required": False},
    {"id": "latch_dual_approval", "path": pathlib.Path("build/latch/prove-latch-approval-latest.json"), "required": False},
    {"id": "circuit_breakers", "path": pathlib.Path("build/breakers/prove-breakers-latest.json"), "required": False},
    {"id": "candle_correctness", "path": pathlib.Path("build/candles/prove-candles-latest.json"), "required": False},
    {"id": "snapshot_verify", "path": pathlib.Path("build/snapshot/snapshot-verify-latest.json"), "required": False},
    {"id": "model_check", "path": pathlib.Path("build/model-check/model-check-latest.json"), "required": False},
    {"id": "service_modes", "path": pathlib.Path("build/service-modes/verify-service-modes-latest.json"), "required": False},
    {"id": "shadow_verify", "path": pathlib.Path("build/shadow/shadow-verify-latest.json"), "required": False},
    {"id": "ws_resume_smoke", "path": pathlib.Path("build/ws/ws-resume-smoke.json"), "required": False},
    {"id": "safety_case_manifest", "path": pathlib.Path(rel(safety_case_manifest)) if safety_case_manifest else None, "required": True},
    {"id": "safety_case_artifact", "path": pathlib.Path(rel(safety_case_artifact)) if safety_case_artifact else None, "required": True},
    {"id": "safety_case_sha256", "path": pathlib.Path(rel(safety_case_sha)) if safety_case_sha else None, "required": True},
    {"id": "gsn_template", "path": pathlib.Path("assurance/GSN.md"), "required": True},
]

rows = []
required_missing = []
for item in evidence:
    p = item["path"]
    exists = bool(p and (root / p).exists())
    path_value = str(p) if p else None
    row = {
        "id": item["id"],
        "required": bool(item["required"]),
        "exists": exists,
        "path": path_value,
    }
    if row["required"] and not row["exists"]:
        required_missing.append(item["id"])
    rows.append(row)

pack = {
    "generated_at_utc": generated_at,
    "git_commit": git_commit,
    "git_branch": git_branch,
    "ok": len(required_missing) == 0,
    "required_missing": required_missing,
    "evidence": rows,
    "claims": [
        {"id": "G1", "text": "Core and ledger invariants hold after replay/recovery."},
        {"id": "G2", "text": "Duplicate event injection has exactly-once effect on balances."},
        {"id": "G3", "text": "Reconciliation breach triggers safety mode and requires explicit release."},
        {"id": "G4", "text": "Crash drills preserve deterministic core hash and prevent ledger double-apply."},
        {"id": "G5", "text": "Order notional/quantity circuit breakers reject oversized risk-taking orders."},
        {"id": "G6", "text": "Service mode matrix is verified against executable tests for mode enforcement."},
        {"id": "G7", "text": "Shadow verification recomputes candles and balance hashes without divergence."},
        {"id": "G8", "text": "Idempotency scope is isolated by user and command type with server-clock TTL expiry."},
        {"id": "G9", "text": "Reconciliation latch release can enforce dual approval with distinct approvers."},
        {"id": "G10", "text": "Broker bounce drill confirms event log durability and post-restart produce/consume continuity."},
        {"id": "G11", "text": "WS resume flow replays missed trade ranges and falls back to snapshot when history gaps are detected."},
        {"id": "G12", "text": "Candle correctness proof confirms canonical rebuild and online aggregation converge under out-of-order and duplicate trades."},
        {"id": "G13", "text": "Snapshot verify drill validates checksum and snapshot+WAL restore rehearsal consistency."},
        {"id": "G14", "text": "Core invariants scan enforces sequence monotonicity and rejects illegal order lifecycle transitions in WAL events."},
        {"id": "G15", "text": "Staged load bundle report captures smoke/10k/50k profile outcomes in one artifact for performance regression tracking."},
        {"id": "G16", "text": "Startup guardrails drill continuously verifies fail-closed production bootstrap policy across edge/core/ledger services."},
        {"id": "G17", "text": "Audit-chain verification produces a deterministic head hash for tamper-evidence checks on admin emergency action logs."},
        {"id": "G18", "text": "PII log scan gate detects email/phone/SSN patterns in generated operational artifacts and fails verification when hits exist."},
    ],
}

pack_json.parent.mkdir(parents=True, exist_ok=True)
with open(pack_json, "w", encoding="utf-8") as f:
    json.dump(pack, f, indent=2, sort_keys=True)
    f.write("\n")

lines = [
    "# Assurance Pack",
    "",
    f"- generated_at_utc: `{generated_at}`",
    f"- git_commit: `{git_commit}`",
    f"- git_branch: `{git_branch}`",
    f"- ok: `{str(pack['ok']).lower()}`",
    "",
    "## Claims",
]
for claim in pack["claims"]:
    lines.append(f"- `{claim['id']}` {claim['text']}")

lines += [
    "",
    "## Evidence Status",
    "",
    "| id | required | exists | path |",
    "|---|---:|---:|---|",
]
for row in rows:
    lines.append(
        f"| `{row['id']}` | `{str(row['required']).lower()}` | `{str(row['exists']).lower()}` | `{row['path'] or '-'}" + "` |"
    )

if required_missing:
    lines += [
        "",
        "## Missing Required Evidence",
        "",
    ]
    for item in required_missing:
        lines.append(f"- `{item}`")

lines += [
    "",
    f"- pack_json: `{pack_json}`",
]

pack_md.parent.mkdir(parents=True, exist_ok=True)
with open(pack_md, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY

PACK_OK="$(
  python3 - "$PACK_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
print("true" if payload.get("ok") else "false")
PY
)"

echo "assurance_pack_json=${PACK_JSON}"
echo "assurance_pack_markdown=${PACK_MD}"
echo "assurance_pack_ok=${PACK_OK}"

if [[ "${PACK_OK}" != "true" && "${ALLOW_MISSING}" != "true" ]]; then
  echo "assurance pack missing required evidence (use --allow-missing to bypass)" >&2
  exit 1
fi
