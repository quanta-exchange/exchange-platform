#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/change-workflow-${TS_ID}}"
LOG_FILE="$OUT_DIR/change-workflow.log"

CHANGE_ID="${CHANGE_ID:-rbchg-${TS_ID}}"
REQUESTED_BY="${REQUESTED_BY:-runbook-requester}"
APPROVER_A="${APPROVER_A:-runbook-approver-a}"
APPROVER_B="${APPROVER_B:-runbook-approver-b}"
APPLIED_BY="${APPLIED_BY:-runbook-applier}"
APPLY_COMMAND="${APPLY_COMMAND:-echo runbook-apply-ok}"

CHANGE_ROOT="$OUT_DIR/changes/requests"
CHANGE_AUDIT_FILE="$OUT_DIR/change-audit.log"
mkdir -p "$OUT_DIR"

{
  echo "runbook=change_workflow"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  PROPOSAL_OUT="$(
    CHANGE_ROOT="$CHANGE_ROOT" CHANGE_AUDIT_FILE="$CHANGE_AUDIT_FILE" \
      "$ROOT_DIR/scripts/change_proposal.sh" \
      --change-id "$CHANGE_ID" \
      --title "runbook change workflow drill" \
      --risk-level HIGH \
      --requested-by "$REQUESTED_BY" \
      --summary "exercise proposal-approval-apply-audit-chain flow"
  )"
  echo "$PROPOSAL_OUT"
  CHANGE_DIR="$(printf '%s\n' "$PROPOSAL_OUT" | awk -F= '/^change_dir=/{print $2}')"
  if [[ -z "$CHANGE_DIR" ]]; then
    echo "failed to parse change_dir from proposal output" >&2
    exit 1
  fi

  CHANGE_AUDIT_FILE="$CHANGE_AUDIT_FILE" "$ROOT_DIR/scripts/change_approve.sh" \
    --change-dir "$CHANGE_DIR" \
    --approver "$APPROVER_A" \
    --note "runbook approval A"
  CHANGE_AUDIT_FILE="$CHANGE_AUDIT_FILE" "$ROOT_DIR/scripts/change_approve.sh" \
    --change-dir "$CHANGE_DIR" \
    --approver "$APPROVER_B" \
    --note "runbook approval B"

  CHANGE_AUDIT_FILE="$CHANGE_AUDIT_FILE" "$ROOT_DIR/scripts/apply_change.sh" \
    --change-dir "$CHANGE_DIR" \
    --command "$APPLY_COMMAND" \
    --skip-verification \
    --applied-by "$APPLIED_BY"

  VERIFY_OUT="$(
    "$ROOT_DIR/scripts/verify_change_audit_chain.sh" \
      --audit-file "$CHANGE_AUDIT_FILE" \
      --out-dir "$OUT_DIR" \
      --require-events \
      --require-change-id "$CHANGE_ID" \
      --require-applied
  )"
  echo "$VERIFY_OUT"
  VERIFY_REPORT="$(printf '%s\n' "$VERIFY_OUT" | awk -F= '/^verify_change_audit_chain_report=/{print $2}')"
  VERIFY_HEAD="$(printf '%s\n' "$VERIFY_OUT" | awk -F= '/^verify_change_audit_chain_head=/{print $2}')"

  SUMMARY_FILE="$OUT_DIR/change-workflow-summary.json"
  python3 - "$SUMMARY_FILE" "$CHANGE_ID" "$CHANGE_DIR" "$CHANGE_AUDIT_FILE" "$VERIFY_REPORT" "$VERIFY_HEAD" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

summary_file = pathlib.Path(sys.argv[1]).resolve()
payload = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": True,
    "change_id": sys.argv[2],
    "change_dir": sys.argv[3],
    "change_audit_file": sys.argv[4],
    "verify_change_audit_chain_report": sys.argv[5],
    "verify_change_audit_chain_head": sys.argv[6],
}
summary_file.parent.mkdir(parents=True, exist_ok=True)
with open(summary_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
PY

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  echo "runbook_change_workflow_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
