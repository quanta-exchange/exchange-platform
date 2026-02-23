#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/runbooks/startup-guardrails-${TS_ID}}"
LOG_FILE="$OUT_DIR/startup-guardrails.log"

ALLOW_CORE_FAIL="${RUNBOOK_ALLOW_CORE_FAIL:-false}"
SKIP_CORE="${RUNBOOK_SKIP_CORE_GUARDRAILS:-false}"

mkdir -p "$OUT_DIR"

run_required() {
  local name="$1"
  shift
  local step_log="$OUT_DIR/${name}.log"
  if "$@" >"$step_log" 2>&1; then
    echo "${name}_ok=true"
    echo "${name}_log=${step_log}"
  else
    echo "${name}_ok=false"
    echo "${name}_log=${step_log}"
    tail -n 60 "$step_log" >&2 || true
    return 1
  fi
}

{
  echo "runbook=startup_guardrails"
  echo "started_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-before.json" || true

  run_required edge_guardrails_tests \
    go test ./services/edge-gateway/internal/gateway \
    -run 'TestNewAcceptsProductionGuardrailConfig|TestNewRejectsInsecureProductionGuardrails'

  run_required ledger_guardrails_tests \
    ./gradlew :services:ledger-service:test --tests com.quanta.exchange.ledger.StartupGuardrailsTest

  core_guardrails_ok=false
  core_guardrails_skipped=false
  core_guardrails_reason=""
  core_guardrails_log="$OUT_DIR/core_guardrails_tests.log"
  if [[ "$SKIP_CORE" == "true" ]]; then
    core_guardrails_skipped=true
    core_guardrails_reason="RUNBOOK_SKIP_CORE_GUARDRAILS=true"
  elif cargo test -p trading-core --bin trading-core runtime_guardrails >"$core_guardrails_log" 2>&1; then
    core_guardrails_ok=true
  elif [[ "$ALLOW_CORE_FAIL" == "true" ]]; then
    core_guardrails_skipped=true
    core_guardrails_reason="RUNBOOK_ALLOW_CORE_FAIL=true"
  else
    echo "core_guardrails_ok=false"
    echo "core_guardrails_log=$core_guardrails_log"
    tail -n 80 "$core_guardrails_log" >&2 || true
    exit 1
  fi

  echo "core_guardrails_ok=${core_guardrails_ok}"
  echo "core_guardrails_skipped=${core_guardrails_skipped}"
  if [[ -n "$core_guardrails_reason" ]]; then
    echo "core_guardrails_reason=${core_guardrails_reason}"
  fi
  echo "core_guardrails_log=${core_guardrails_log}"

  "$ROOT_DIR/scripts/system_status.sh" --out-dir "$OUT_DIR" --report-name "status-after.json" || true
  echo "runbook_startup_guardrails_ok=true"
  echo "runbook_output_dir=$OUT_DIR"
} | tee "$LOG_FILE"
