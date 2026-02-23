# Exchange Platform Monorepo

Production-oriented spot exchange monorepo with locked stack and gate-driven delivery.

## Locked stack
- Trading Core: Rust
- Edge Gateway: Go (REST + WS)
- Ledger/Settlement: Kotlin + Spring Boot + PostgreSQL
- Contracts/Event Log: Protobuf + Redpanda(Kafka API)
- Streaming: Flink
- Cache/History/Archive: Redis / ClickHouse / MinIO(S3)
- Infra/Ops: Docker Compose(local), Kubernetes + OTel + GitOps(target)

## Repo layout
```text
contracts/
  proto/                  # source-of-truth protobuf schemas
  gen/                    # generated stubs (go/rust/kotlin)
services/
  trading-core/           # Rust
  edge-gateway/           # Go
  ledger-service/         # Kotlin
streaming/
  flink-jobs/             # Java/Flink skeleton
infra/
  compose/                # local infra stack
  k8s/                    # k8s placeholders
  gitops/                 # gitops placeholders
scripts/
  smoke_g0.sh             # gate G0 local smoke
  smoke_g3.sh             # gate G3 ledger safety smoke
  smoke_reconciliation_safety.sh # reconciliation lag/safety auto-mode smoke
  exactly_once_stress.sh  # duplicate trade injection (exactly-once effect proof)
  chaos/                  # standardized crash drills (core/ledger/redpanda/full)
  smoke_e2e.sh            # minimal E2E: Edge -> Core -> Kafka -> Ledger
  smoke_match.sh          # Gate G1 real match smoke (BUY+SELL crossing)
  load_smoke.sh           # I-0105 load smoke harness
  load_10k.sh             # staged load profile (10k orders baseline)
  load_50k.sh             # staged load profile (50k orders baseline)
  load_all.sh             # staged load bundle runner (smoke/10k/50k)
  dr_rehearsal.sh         # I-0106 backup/restore rehearsal
  safety_case.sh          # I-0108 evidence bundle generator (base + extended evidence)
  assurance_pack.sh       # G31 assurance pack generator (claims + evidence index)
  controls_check.sh       # G32 controls catalog automated checker
  verification_factory.sh # G33 continuous verification wrapper (optional load-all/startup-guardrails + safety->controls->controls-freshness->audit-chain->change-audit-chain->pii-scan->anomaly-detector->idempotency->latch-approval->budget-freshness->model-check->breakers->candles->snapshot->service-modes->ws-resume-smoke->shadow-verify->compliance->transparency->access->budget->assurance)
  release_gate.sh         # G4.6 release blocking gate wrapper
  safety_budget_check.sh  # G31 safety budget checker
  anomaly_detector.sh     # G13 anomaly detector + alert webhook emitter
  anomaly_detector_smoke.sh # G13 anomaly detector webhook smoke
  rbac_sod_check.sh       # G32 segregation-of-duties RBAC checker
  compliance_evidence.sh  # G36 controls-to-framework evidence pack
  transparency_report.sh  # G34 public transparency report generator
  adversarial_tests.sh    # G30 adversarial reliability bundle
  prove_determinism.sh    # G4.6 deterministic replay proof runner
  prove_idempotency_scope.sh # G4.1 idempotency scope/TTL proof runner
  prove_latch_approval.sh # G4.1 reconciliation latch approval proof runner
  prove_budget_freshness.sh # G31 safety budget artifact freshness proof runner
  prove_controls_freshness.sh # G32 controls evidence freshness proof runner
  prove_exactly_once_million.sh # G4.1 million-duplicate exactly-once proof runner
  prove_breakers.sh       # G35 circuit-breaker proof runner
  prove_candles.sh        # G17 candle correctness proof runner
  snapshot_verify.sh      # G4.2 snapshot checksum + restore rehearsal verifier
  verify_service_modes.sh # G26 service mode matrix verification
  model_check.sh          # G28 state-machine model checker
  shadow_verify.sh        # G33 production shadow verification
  archive_range.sh        # G21 legal archive capture
  verify_archive.sh       # G21 archive checksum verifier
  verify_audit_chain.sh   # G25 tamper-evident audit chain verifier
  verify_change_audit_chain.sh # G10 change-workflow audit chain verifier
  pii_log_scan.sh         # G20 log PII leak gate
  change_proposal.sh      # G10 change proposal creation
  change_approve.sh       # G10 approval recording
  apply_change.sh         # G10 apply + verification evidence
  break_glass.sh          # G10 emergency privilege with TTL + audit log
  access_review.sh        # G36 access review report
  system_status.sh        # G13 runbook status snapshot (core/edge/ledger/kafka/ws metrics)
  policy_sign.sh          # G29 policy signing
  policy_verify.sh        # G29 policy signature verification
  policy_smoke.sh         # G29 sign+verify smoke
  ws_smoke.sh             # WS slow-consumer backpressure smoke
  ws_resume_smoke.sh      # WS resume/gap recovery smoke
  ws_resume_client.go     # WS resume helper (SUB/RESUME assertion client)
runbooks/
  crash_recovery.sh       # crash recovery runbook-as-code (snapshot+chaos)
  crash_recovery.md       # crash recovery drill notes
  audit_chain_tamper.sh   # audit hash-chain tamper drill
  audit_chain_tamper.md   # audit hash-chain tamper drill notes
  lag_spike.sh            # reconciliation lag spike automated drill
  load_regression.sh      # load regression automated drill
  game_day_anomaly.sh     # anomaly game-day automated drill
  game_day_anomaly.md     # anomaly game-day drill notes
  change_workflow.sh      # change workflow (proposal/approval/apply/audit-chain) automated drill
  change_workflow.md      # change workflow drill notes
  budget_failure.sh       # safety budget failure diagnosis automated drill
  budget_failure.md       # safety budget failure drill notes
  startup_guardrails.sh   # startup guardrails verification drill
  startup_guardrails.md   # startup guardrails drill notes
  ws_drop_spike.sh        # ws drop spike automated drill
  ws_resume_gap_spike.sh  # ws resume gap spike automated drill
tools/external-replay/
  external_replay_demo.sh # external verifier demo for safety-case artifacts
policies/
  trading-policy.v1.json  # baseline policy-as-code document
safety/
  budgets.yaml            # safety budget thresholds
compliance/
  mapping.yaml            # controls-to-framework mapping
changes/
  templates/change-proposal.md
security/
  rbac_roles.yaml
web-user/
  src/                    # web-user frontend (Vite + React)
```

## Local Quickstart (E2E happy path)
1) Bring up infra dependencies:
```bash
docker compose -f infra/compose/docker-compose.yml up -d
```

2) Run the minimal E2E smoke (starts core/edge/ledger locally):
```bash
./scripts/smoke_e2e.sh
```

## Dev environment doctor (fresh macOS)
Run this first on a new machine:
```bash
make doctor
```

If doctor fails, install missing tools with Homebrew (example):
```bash
brew install protobuf go openjdk@21
```

For Rust, install via rustup:
```bash
curl https://sh.rustup.rs -sSf | sh
```

## Web user frontend (alpha)
```bash
cd web-user
npm install
npm run dev
```

- default dev URL: `http://localhost:5173`
- default proxy target: `http://localhost:8081` (override: `VITE_PROXY_TARGET`)

## Gate G0 commands
### Production startup guardrails (Edge)
- Enable guardrails with `EDGE_ENV=prod` (or `EDGE_OTEL_ENV=prod` when `EDGE_ENV` is unset).
- In production mode, edge startup fails if any of these are true:
  - `EDGE_ALLOW_INSECURE_NO_AUTH=true`
  - `EDGE_ENABLE_SMOKE_ROUTES=true`
  - `EDGE_SEED_MARKET_DATA=true`
  - `EDGE_DISABLE_CORE=true`
  - `EDGE_OTEL_INSECURE=true`
  - API secrets are not configured
  - WS origin allowlist is empty

### Production startup guardrails (Trading Core)
- Enable guardrails with `CORE_ENV=prod` (accepted aliases: `production`, `live`).
- In production mode, trading-core startup fails if any of these are true:
  - `CORE_STUB_TRADES=true`
  - `CORE_WAL_DIR` points to `/tmp`
  - `CORE_OUTBOX_DIR` points to `/tmp`
  - `CORE_KAFKA_BROKERS` contains `localhost:*` or `127.0.0.1:*`

### Production startup guardrails (Ledger Service)
- Enable guardrails with `LEDGER_ENV=prod` (accepted aliases: `production`, `live`).
- In production mode, ledger startup fails if any of these are true:
  - `LEDGER_ADMIN_TOKEN` is empty
  - `LEDGER_KAFKA_ENABLED=false`
  - `LEDGER_KAFKA_BOOTSTRAP` contains `localhost`, `127.0.0.1`, or `::1`
  - `LEDGER_RECONCILIATION_CORE_GRPC_ADDR` contains `localhost`, `127.0.0.1`, or `::1`
  - `LEDGER_RECONCILIATION_SAFETY_LATCH_ENABLED=false`
  - `LEDGER_RECONCILIATION_LATCH_RELEASE_REQUIRE_DUAL_APPROVAL=false`

### 1) Contracts
If `buf` is installed locally:
```bash
buf lint
buf generate
```
If not, run with Docker:
```bash
docker run --rm -v "$PWD":/workspace -w /workspace bufbuild/buf:1.37.0 lint
docker run --rm -v "$PWD":/workspace -w /workspace bufbuild/buf:1.37.0 generate
```

### 2) Tests
```bash
cargo test
go test ./...
./gradlew test
```


Rust protobuf build note (Trading Core):
- `cargo test -p trading-core` requires `protoc` + Google well-known includes (`google/protobuf/*.proto`).
- On macOS this is normally provided by `brew install protobuf` (`/opt/homebrew/include` or `/usr/local/include`).
- If installed in a custom location, set `PROTOC_INCLUDE=/path/to/include`.

### 2.1) Ops/Infra validation
```bash
./scripts/validate_infra.sh
make load-smoke
make load-10k   # profile defaults can be overridden with LOAD_10K_* env vars
make load-50k   # profile defaults can be overridden with LOAD_50K_* env vars
make load-all   # runs smoke -> 10k -> 50k and writes combined report
./scripts/dr_rehearsal.sh
./scripts/invariants.sh
./scripts/snapshot_verify.sh
make safety-case
# optional full safety-case proof set (exactly-once + idempotency-scope + latch-approval + reconciliation + chaos + determinism + breakers + service-mode matrix 포함)
make safety-case-extended
```
`load-*` profiles assume Trading Core is reachable (`EDGE_CORE_ADDR`, default `localhost:50051`).  
For gateway-only dry-runs, set `EDGE_DISABLE_CORE=true` and disable threshold gate (`LOAD_CHECK=false`, `LOAD_10K_CHECK=false`, `LOAD_50K_CHECK=false`).
`make load-all` outputs:
- `load_all_report=build/load/load-all-<timestamp>.json`
- `load_all_latest=build/load/load-all-latest.json`
- `load_all_ok=true|false`

`./scripts/invariants.sh` behavior:
- always checks ledger invariants (`/v1/admin/invariants/check`)
- Core WAL seq checks default to `INVARIANTS_CORE_MODE=auto`
  - `auto`: run only when WAL directory (`CORE_WAL_DIR`) exists
  - `require`: fail if WAL is unavailable or non-monotonic seq is detected
  - `off`: skip Core checks
  - includes order lifecycle consistency checks (`OrderAccepted` → trade/cancel/reject without illegal back-transitions)
- ClickHouse checks default to `INVARIANTS_CLICKHOUSE_MODE=auto`
  - `auto`: run only when ClickHouse is reachable
  - `require`: fail if ClickHouse is unreachable or invalid rows are found
  - `off`: skip ClickHouse checks
- outputs:
  - `build/invariants/ledger-invariants.json`
  - `build/invariants/core-invariants.json`
  - `build/invariants/clickhouse-invariants.json`
  - `build/invariants/invariants-summary.json`

### 3) Infra up
```bash
docker compose -f infra/compose/docker-compose.yml up -d
```

### 4) Smoke (minimum path)
```bash
./scripts/smoke_g0.sh
```
This script verifies:
- order creation with `Idempotency-Key`
- synthetic trade settlement row appended to Postgres
- WebSocket `TradeExecuted` and `CandleUpdated` fan-out observed

### 5) Smoke (ledger safety path)
```bash
./scripts/smoke_g3.sh
```

### 6) Smoke (E2E wiring)
```bash
./scripts/smoke_e2e.sh
```
This script verifies:
- order creation on edge with accepted response
- `TradeExecuted` publish to `core.trade-events.v1`
- ledger append lookup for the trade via REST

### 7) Smoke (reconciliation safety auto-trigger)
```bash
./scripts/smoke_reconciliation_safety.sh
```
This script verifies:
- core trade seq keeps moving while settlement consumer is paused
- reconciliation lag grows above threshold
- ledger auto-triggers `CANCEL_ONLY` safety mode on trading core
- new orders are rejected with `CANCEL_ONLY`
- after lag recovery, safety latch is manually released via admin API
- trading returns to non-`CANCEL_ONLY` mode

Success output includes:
- `smoke_reconciliation_safety_success=true`
- `smoke_reconciliation_report=build/reconciliation/smoke-reconciliation-safety.json`

### 8) E2E Smoke (no frontend, real matching path)
Exact command sequence on a fresh machine:
```bash
make doctor
docker compose -f infra/compose/docker-compose.yml up -d
./scripts/smoke_match.sh
```

### 9) Exactly-once stress (duplicate injection)
```bash
# default: 10,000 duplicate submissions, configurable up to 1,000,000+
REPEATS=1000000 CONCURRENCY=64 ./scripts/exactly_once_stress.sh
```
This script verifies:
- same `tradeId` is injected repeatedly
- ledger applies exactly once (`applied=true` only once)
- all other submissions are blocked as duplicates
- balances reflect a single settlement effect

Success output includes:
- `exactly_once_stress_success=true`
- `exactly_once_report=build/exactly-once/exactly-once-stress.json`

Million-duplicate proof wrapper:
```bash
make prove-exactly-once-million
```
Outputs:
- `prove_exactly_once_million_report=build/exactly-once/prove-exactly-once-million-<timestamp>.json`
- `prove_exactly_once_million_latest=build/exactly-once/prove-exactly-once-million-latest.json`
- `prove_exactly_once_million_ok=true|false`

### 10) Chaos drills (standardized)
```bash
make chaos-full      # core+ledger kill/restart replay drill
make chaos-core      # core-only kill/restart drill
make chaos-ledger    # ledger-only kill/restart drill
make chaos-redpanda  # broker bounce drill
```
`chaos-full` success output includes:
- `chaos_replay_success=true`
- `core_recovery_hash` continuity proof
- `ledger_duplicate_rows=0`
- `invariants_ok=true`  
- `chaos_replay_report=build/chaos/chaos-replay.json`
  - in stub-trade mode, `invariants_warning=negative_balances_present_under_stub_mode` can appear

`chaos-redpanda` success output includes:
- `redpanda_broker_bounce_success=true`
- `redpanda_broker_bounce_report=build/chaos/redpanda-broker-bounce.json`
- `invariants_ok=true|false` (controlled by `CHAOS_REDPANDA_CHECK_INVARIANTS=off|auto|require`, default `auto`)

### 10.1) WS slow-consumer smoke
```bash
./scripts/ws_smoke.sh
```
Success output includes:
- `ws_smoke_success=true`
- `ws_smoke_report=build/ws/ws-smoke.json`

### 10.2) WS resume/gap-recovery smoke
```bash
make ws-resume-smoke
```
Success output includes:
- `ws_resume_smoke_success=true`
- `ws_resume_gap_first_type=Snapshot|Missed`
- `ws_resume_gaps>=1`
- `ws_resume_smoke_report=build/ws/ws-resume-smoke.json`

WS alert rule examples:
- `infra/observability/ws-alert-rules.example.yml`
- includes `WSResumeGapSpike` (`increase(ws_resume_gaps[10m])`)

### 10.3) Candle correctness proof
```bash
make prove-candles
```
Success output includes:
- `prove_candles_ok=true`
- `prove_candles_latest=build/candles/prove-candles-latest.json`

### 10.4) Snapshot verify rehearsal
```bash
make snapshot-verify
```
Success output includes:
- `snapshot_verify_ok=true`
- `snapshot_verify_latest=build/snapshot/snapshot-verify-latest.json`

### 11) Safety case bundle (extended)
```bash
make safety-case-extended
```
`scripts/safety_case.sh --run-extended-checks`는 다음 증거 파일을 번들에 포함합니다:
- `build/load/load-smoke.json`
- `build/load/load-all-latest.json` (있을 때 자동 포함)
- `build/dr/dr-report.json`
- `build/invariants/ledger-invariants.json`
- `build/invariants/core-invariants.json`
- `build/invariants/invariants-summary.json`
- `build/audit/verify-audit-chain-latest.json` (있을 때 자동 포함)
- `build/change-audit/verify-change-audit-chain-latest.json` (있을 때 자동 포함)
- `build/controls/prove-controls-freshness-latest.json` (있을 때 자동 포함)
- `build/exactly-once/exactly-once-stress.json`
- `build/exactly-once/prove-exactly-once-million-latest.json` (있을 때 자동 포함)
- `build/idempotency/prove-idempotency-latest.json`
- `build/latch/prove-latch-approval-latest.json`
- `build/safety/prove-budget-freshness-latest.json`
- `build/reconciliation/smoke-reconciliation-safety.json`
- `build/chaos/chaos-replay.json`
- `build/ws/ws-smoke.json`
- `build/ws/ws-resume-smoke.json`
- `build/determinism/prove-determinism-latest.json`
- `build/breakers/prove-breakers-latest.json`
- `build/candles/prove-candles-latest.json`
- `build/snapshot/snapshot-verify-latest.json`
- `build/service-modes/verify-service-modes-latest.json`

### 12) Assurance pack (claims + evidence index)
```bash
make assurance-pack
```
Success output includes:
- `assurance_pack_json=build/assurance/<timestamp>/assurance-pack.json`
- `assurance_pack_markdown=build/assurance/<timestamp>/assurance-pack.md`
- `assurance_pack_ok=true|false`

### 13) Controls check (controls catalog gate)
```bash
make controls-check
```
Success output includes:
- `controls_check_report=build/controls/controls-check-<timestamp>.json`
- `controls_check_latest=build/controls/controls-check-latest.json`
- `controls_check_ok=true|false`
- supports optional control field `max_evidence_age_seconds`
- report fields include `stale_evidence`, `evidence_age_seconds`, `failed_enforced_stale_count`

### 14) Verification factory (single command gate)
```bash
make verification-factory
# include staged load profiles in same gate:
./scripts/verification_factory.sh --run-load-profiles
# include startup guardrails runbook in same gate:
./scripts/verification_factory.sh --run-startup-guardrails
# include change-workflow runbook in same gate:
./scripts/verification_factory.sh --run-change-workflow
# local fallback for core cargo environment:
VERIFICATION_STARTUP_ALLOW_CORE_FAIL=true ./scripts/verification_factory.sh --run-startup-guardrails
```
Success output includes:
- `verification_summary=build/verification/<timestamp>/verification-summary.json`
- `verification_ok=true|false`
- summary includes `run_load_profiles=true|false`, `run_startup_guardrails=true|false`, `run_change_workflow=true|false` and optional artifacts (`load_all_report`, `startup_guardrails_runbook_dir`, `change_workflow_runbook_dir`, `budget_failure_runbook_dir`, `verify_change_audit_chain_report`, `prove_controls_freshness_report`, `prove_budget_freshness_report`, `anomaly_detector_report`)

### 15) Signed policy smoke
```bash
make policy-smoke
```
Success output includes:
- `policy_smoke_ok=true`
- `policy_smoke_signature=build/policy-smoke/trading-policy.v1.sig`

### 16) Safety budget check
```bash
make safety-budget
```
Success output includes:
- `safety_budget_report=build/safety/safety-budget-<timestamp>.json`
- `safety_budget_latest=build/safety/safety-budget-latest.json`
- `safety_budget_ok=true|false`
- when reports exist, budget checks include `auditChain`, `changeAuditChain`, `piiLogScan`, `anomaly` gates
- supports report freshness policy via `safety/budgets.yaml`:
  - top-level `freshness.defaultMaxAgeSeconds`
  - per-check override `budgets.<check>.maxAgeSeconds`
  - output fields: `age_seconds`, `max_age_seconds`, `report_time_source`
- `load` check supports policy fields:
  - `mustThresholdsChecked`
  - `mustThresholdsPass`
  - `minOrdersSucceeded`

### 16.1) Safety budget failure runbook
```bash
make runbook-budget-failure
```
Outputs:
- `runbook_budget_failure_ok=true|false`
- `budget_ok=true|false`
- `budget_violation_count=<n>`
- `budget_recommended_action=...`
- `runbook_output_dir=build/runbooks/budget-failure-<timestamp>`

### 17) System status snapshot
```bash
make system-status
```
Success output includes:
- `system_status_report=build/status/system-status-<timestamp>.json`
- `system_status_latest=build/status/system-status-latest.json`
- `system_status_ok=true|false`
- report includes `checks.compliance.controls`, `checks.compliance.audit_chain`, `checks.compliance.change_audit_chain`, `checks.compliance.pii_log_scan`, `checks.compliance.safety_budget`, `checks.compliance.proofs` snapshots when latest artifacts exist

### 17.1) Anomaly detector
```bash
make anomaly-detector
# deterministic drill mode:
./scripts/anomaly_detector.sh --force-anomaly --allow-anomaly
# webhook E2E smoke:
make anomaly-smoke
```
Success output includes:
- `anomaly_report=build/anomaly/anomaly-detector-<timestamp>.json`
- `anomaly_latest=build/anomaly/anomaly-detector-latest.json`
- `anomaly_detected=true|false`
- `anomaly_recommended_action=NONE|INVESTIGATE|CANCEL_ONLY|WITHDRAW_HALT`
- smoke output: `anomaly_smoke_report=build/anomaly/smoke-<timestamp>/anomaly-smoke.json`, `anomaly_smoke_ok=true|false`

### 18) Runbook-as-code drills
```bash
make runbook-lag-spike
make runbook-load-regression
make runbook-ws-drop
make runbook-ws-resume-gap
make runbook-crash-recovery
make runbook-startup-guardrails
make runbook-game-day-anomaly
make runbook-audit-tamper
make runbook-change-workflow
make runbook-budget-failure
```
Success output includes:
- `runbook_lag_spike_ok=true` or `runbook_load_regression_ok=true` or `runbook_ws_drop_spike_ok=true` or `runbook_ws_resume_gap_spike_ok=true` or `runbook_startup_guardrails_ok=true` or `runbook_game_day_anomaly_ok=true` or `runbook_audit_tamper_ok=true` or `runbook_change_workflow_ok=true` or `runbook_budget_failure_ok=true`
- `runbook_output_dir=build/runbooks/...`
- `status-before.json` / `status-after.json` (core/edge/ledger/kafka/ws snapshot)

### 19) Compliance evidence pack
```bash
make compliance-evidence
```
Success output includes:
- `compliance_evidence_report=build/compliance/compliance-evidence-<timestamp>.json`
- `compliance_evidence_latest=build/compliance/compliance-evidence-latest.json`
- `compliance_evidence_ok=true|false`
- report includes stale-evidence summaries: `failed_enforced_stale_count`, `advisory_stale_count`

### 20) Transparency report
```bash
make transparency-report
```
Success output includes:
- `transparency_report_file=build/transparency/transparency-report-<timestamp>.json`
- `transparency_report_latest=build/transparency/transparency-report-latest.json`
- `transparency_report_ok=true|false`
- governance summary now includes `audit_chain`, `change_audit_chain`, `pii_log_scan`, `rbac_sod`, `anomaly_detector`, `controls_freshness_proof`, `budget_freshness_proof` proxies

### 20) External replay demo
```bash
make external-replay-demo
```
Success output includes:
- `external_replay_demo_report=build/external-replay/<timestamp>/external-replay-demo.json`
- `external_replay_demo_ok=true|false`

### 21) Adversarial tests bundle
```bash
make adversarial-tests
```
Success output includes:
- `adversarial_tests_report=build/adversarial/<timestamp>/adversarial-tests.json`
- `adversarial_tests_ok=true|false`

### 22) Change management flow
```bash
./scripts/change_proposal.sh --title "fee policy tweak" --risk-level HIGH --requested-by alice --summary "adjust maker fee"
./scripts/change_approve.sh --change-dir changes/requests/<change-id> --approver bob --note "ops review"
./scripts/change_approve.sh --change-dir changes/requests/<change-id> --approver carol --note "risk review"
./scripts/apply_change.sh --change-dir changes/requests/<change-id> --command "echo apply-ok"
```
Apply success output includes:
- `change_apply_success=true`
- `change_apply_log=...`
- `change_verification_summary=build/verification/<timestamp>/verification-summary.json`
- `change_audit_file=build/change-audit/audit.log`

Runbook shortcut:
```bash
make runbook-change-workflow
# include full verification in apply step:
RUNBOOK_SKIP_VERIFICATION=false make runbook-change-workflow
```
Outputs:
- `runbook_change_workflow_ok=true|false`
- `runbook_output_dir=build/runbooks/change-workflow-<timestamp>`

### 23) Break-glass emergency mode
```bash
./scripts/break_glass.sh enable --ttl-sec 900 --actor oncall --reason "incident response"
./scripts/break_glass.sh status
./scripts/break_glass.sh disable --actor oncall --reason "incident resolved"
```
Outputs:
- `break_glass_enabled=true|false`
- `break_glass_status={...}`
- audit log: `build/break-glass/audit.log`

### 24) Access review
```bash
make access-review
```
Outputs:
- `access_review_report=build/access/access-review-<timestamp>.json`
- `access_review_latest=build/access/access-review-latest.json`
- `access_review_ok=true|false`

### 24.1) RBAC SoD check
```bash
make rbac-sod-check
```
Outputs:
- `rbac_sod_check_report=build/security/rbac-sod-check-<timestamp>.json`
- `rbac_sod_check_latest=build/security/rbac-sod-check-latest.json`
- `rbac_sod_check_ok=true|false`

### 25) Release gate
```bash
make release-gate
# include staged load profiles in gate:
./scripts/release_gate.sh --run-load-profiles
# include startup guardrails runbook in gate:
./scripts/release_gate.sh --run-startup-guardrails
# include change-workflow runbook in gate:
./scripts/release_gate.sh --run-change-workflow
# fail gate on advisory control gaps too:
./scripts/release_gate.sh --strict-controls
```
Outputs:
- `release_gate_report=build/release-gate/release-gate-<timestamp>.json`
- `release_gate_latest=build/release-gate/release-gate-latest.json`
- `release_gate_ok=true|false`
- report includes control health counters: `controls_advisory_missing_count`, `controls_advisory_stale_count`, `controls_failed_enforced_stale_count`
- report includes safety budget context: `safety_budget_ok`, `safety_budget_violations`

### 26) Legal archive capture + verify
```bash
./scripts/archive_range.sh --source-file build/load/load-smoke.json
./scripts/verify_archive.sh --manifest build/archive/<timestamp>/manifest.json
```
Outputs:
- `archive_manifest=build/archive/<timestamp>/manifest.json`
- `verify_archive_ok=true`

### 26.1) Audit hash-chain verify
```bash
make verify-audit-chain
# require at least one audit event:
./scripts/verify_audit_chain.sh --require-events
```
Outputs:
- `verify_audit_chain_report=build/audit/verify-audit-chain-<timestamp>.json`
- `verify_audit_chain_latest=build/audit/verify-audit-chain-latest.json`
- `verify_audit_chain_head=<sha256>`
- `verify_audit_chain_ok=true|false`

### 26.2) Change audit hash-chain verify
```bash
make verify-change-audit-chain
# require at least one change workflow event:
./scripts/verify_change_audit_chain.sh --require-events
# strict change lifecycle check for one change id:
./scripts/verify_change_audit_chain.sh --require-events --require-change-id <change-id> --require-applied
```
Outputs:
- `verify_change_audit_chain_report=build/change-audit/verify-change-audit-chain-<timestamp>.json`
- `verify_change_audit_chain_latest=build/change-audit/verify-change-audit-chain-latest.json`
- `verify_change_audit_chain_head=<sha256>`
- `verify_change_audit_chain_ok=true|false`

### 26.3) PII log scan gate
```bash
make pii-log-scan
# dry-run mode (hits are reported but exit 0):
./scripts/pii_log_scan.sh --allow-hits
```
Outputs:
- `pii_log_scan_report=build/security/pii-log-scan-<timestamp>.json`
- `pii_log_scan_latest=build/security/pii-log-scan-latest.json`
- `pii_log_scan_hit_count=<n>`
- `pii_log_scan_ok=true|false`

`verification_factory.sh` 실행 시에도 `archive-range`/`verify-archive`/`verify-change-audit-chain` 단계가 자동 포함됩니다.  
`--run-load-profiles`를 주면 `load-all` 단계가 추가 실행됩니다.  
`--run-startup-guardrails`를 주면 startup guardrails runbook 단계가 추가 실행됩니다.

### 27) Determinism proof
```bash
RUNS=5 make prove-determinism
```
Outputs:
- `prove_determinism_report=build/determinism/<timestamp>/prove-determinism.json`
- `prove_determinism_ok=true|false`

### 27.1) Idempotency scope proof
```bash
make prove-idempotency
```
Outputs:
- `prove_idempotency_report=build/idempotency/prove-idempotency-<timestamp>.json`
- `prove_idempotency_latest=build/idempotency/prove-idempotency-latest.json`
- `prove_idempotency_ok=true|false`

### 27.2) Latch approval proof
```bash
make prove-latch-approval
```
Outputs:
- `prove_latch_approval_report=build/latch/prove-latch-approval-<timestamp>.json`
- `prove_latch_approval_latest=build/latch/prove-latch-approval-latest.json`
- `prove_latch_approval_ok=true|false`

### 27.3) Budget freshness proof
```bash
make prove-budget-freshness
```
Outputs:
- `prove_budget_freshness_report=build/safety/prove-budget-freshness-<timestamp>.json`
- `prove_budget_freshness_latest=build/safety/prove-budget-freshness-latest.json`
- `prove_budget_freshness_ok=true|false`

### 27.4) Controls freshness proof
```bash
make prove-controls-freshness
```
Outputs:
- `prove_controls_freshness_report=build/controls/prove-controls-freshness-<timestamp>.json`
- `prove_controls_freshness_latest=build/controls/prove-controls-freshness-latest.json`
- `prove_controls_freshness_ok=true|false`

### 27.5) Circuit-breaker proof
```bash
make prove-breakers
```
Outputs:
- `prove_breakers_report=build/breakers/prove-breakers-<timestamp>.json`
- `prove_breakers_latest=build/breakers/prove-breakers-latest.json`
- `prove_breakers_ok=true|false`

### 27.6) Service-mode matrix verification
```bash
make verify-service-modes
```
Outputs:
- `verify_service_modes_report=build/service-modes/verify-service-modes-<timestamp>.json`
- `verify_service_modes_latest=build/service-modes/verify-service-modes-latest.json`
- `verify_service_modes_ok=true|false`

### 28) State-machine model check
```bash
make model-check
```
Outputs:
- `model_check_report=build/model-check/model-check-<timestamp>.json`
- `model_check_latest=build/model-check/model-check-latest.json`
- `model_check_ok=true|false`

### 29) Shadow verification
```bash
make shadow-verify
```
Outputs:
- `shadow_verify_report=build/shadow/shadow-verify-<timestamp>.json`
- `shadow_verify_latest=build/shadow/shadow-verify-latest.json`
- `shadow_verify_ok=true|false`

`smoke_match.sh` verifies these checkpoints:
- (a) trading-core gRPC port is listening
- (b) Edge `POST /v1/orders` reaches Core `PlaceOrder`
- (c) `TradeExecuted` exists on topic `core.trade-events.v1` (via `docker compose exec redpanda rpk ...`)
- (d) ledger reflects `tradeId` through REST (`GET /v1/admin/trades/{tradeId}`)

## Gate G1 status
- Trading Core implements:
  - command contract handling (`PlaceOrder`, `CancelOrder`, `SetSymbolMode`, `CancelAll`)
  - idempotency response cache scoped by `symbol + user + command + idempotency_key`
  - price-time priority orderbook (FIFO in level, best-price across levels)
  - LIMIT/MARKET matching with deterministic sequencing
  - risk hot-path guards (reserve, rate/open-order limits, price band)
  - WAL (CRC framed records) with durable-before-outbox commit line
  - snapshot + WAL-tail recovery
  - determinism state hashing and replay checks
  - fencing token checks for split-brain defense
  - durable outbox with retry-safe publish cursor
- Edge Gateway implements:
  - `/v1/orders` routed to Trading Core gRPC `PlaceOrder` (no local accepted fallback)
  - Kafka `TradeExecuted` consume path for WS market stream updates
  - local order status cache updated from core responses + trade events (`ACCEPTED/PARTIALLY_FILLED/FILLED`)

Market order liquidity policy (v1):
- partial fills are allowed
- unfilled remainder is canceled (non-resting)

## Gate G3 status
- Ledger service implements:
  - append-only double-entry schema + Flyway migration
  - idempotent settlement consumer path (`trade_id` dedup via unique trade reference)
  - reserve model (`available`↔`hold`) for reserve/release/fill
  - balances materialization and rebuild endpoint
  - invariant checks + reconciliation gap tracking
  - periodic reconciliation evaluation + history + auto safety-mode trigger
  - correction workflow (request, 2-person approval, reversal apply)
  - Kafka consumer baseline (`LEDGER_KAFKA_ENABLED=true`)

## Gate G2/3 parallel status (B-0401~B-0403 baseline)
- Streaming module includes deterministic:
  - 1m candle aggregation with boundary finalization and seq-preferred out-of-order handling
  - rolling 24h ticker aggregation
- ClickHouse init schema added for:
  - `exchange.trades` (partition by day, order by symbol+time+seq)
  - `exchange.candles` (partition by day, order by symbol+interval+open_time)

## Gate G4 proximity status (I-0101~I-0108 baseline)
- Kubernetes baseline manifests:
  - namespaces (`core`, `edge`, `ledger`, `streaming`, `infra`)
  - deny-by-default network policies with explicit allow rules
  - RBAC and JIT access templates
- GitOps baseline:
  - ArgoCD `AppProject`, root app-of-apps, `dev/staging/prod` applications
- Observability baseline:
  - OTel collector spanmetrics pipeline and Prometheus scraping
  - edge request tracing + `X-Trace-Id` response header
- Security/ops baseline:
  - secrets policy + KMS/HSM plan
  - secret rotation drill and JIT access helper scripts
- Release evidence baseline:
  - load smoke report
  - DR rehearsal report
  - `make safety-case` artifact bundle + integrity hash
  - `make safety-case-extended` for exactly-once/idempotency-scope/latch-approval/reconciliation/chaos/determinism evidence 포함 번들

## Service endpoints (local)
- Edge Gateway: `http://localhost:8081`
  - `GET /healthz`
  - `GET /readyz`
  - `GET /metrics`
  - `POST /v1/auth/signup`
  - `POST /v1/auth/login`
  - `GET /v1/auth/me`
  - `POST /v1/auth/logout`
  - `GET /v1/account/balances`
  - `GET /v1/account/portfolio`
  - `POST /v1/orders`
  - `DELETE /v1/orders/{orderId}`
  - `GET /v1/orders/{orderId}`
  - `POST /v1/smoke/trades` (test-only; requires `EDGE_ENABLE_SMOKE_ROUTES=true`)
  - `GET /v1/markets/{symbol}/trades`
  - `GET /v1/markets/{symbol}/orderbook`
  - `GET /v1/markets/{symbol}/candles`
  - `GET /v1/markets/{symbol}/ticker`
  - `GET /ws`
- Ledger Service: `http://localhost:8082`
  - `GET /healthz`
  - `GET /readyz`
  - `GET /metrics`
  - `POST /v1/internal/trades/executed`
  - `POST /v1/internal/orders/reserve`
  - `POST /v1/internal/orders/release`
  - `POST /v1/internal/reconciliation/engine-seq`
  - `POST /v1/admin/adjustments`
  - `GET /v1/admin/balances` (optional `X-Admin-Token` when `LEDGER_ADMIN_TOKEN` set)
  - `GET /v1/balances` (legacy alias, deprecated)
  - `POST /v1/admin/rebuild-balances`
  - `POST /v1/admin/invariants/check`
  - `GET /v1/admin/reconciliation/{symbol}`
  - `GET /v1/admin/reconciliation/status` (`historyLimit`, optional `historyBeforeId` cursor; response has `nextHistoryBeforeId`)
  - `POST /v1/admin/reconciliation/latch/{symbol}/release`
  - `POST /v1/admin/consumers/settlement/pause`
  - `POST /v1/admin/consumers/settlement/resume`
  - `GET /v1/admin/consumers/settlement/status`
  - `POST /v1/admin/corrections/requests`
  - `POST /v1/admin/corrections/{correctionId}/approve`
  - `POST /v1/admin/corrections/{correctionId}/apply`
- Postgres: `localhost:25432`
- Redpanda Kafka: `localhost:29092`
- Redpanda HTTP proxy: `localhost:28082`
- Redis: `localhost:26380`
- ClickHouse HTTP/TCP: `localhost:28123` / `localhost:29000`
- MinIO API/Console: `localhost:29002` / `localhost:29001`
- OTel collector OTLP gRPC/HTTP: `localhost:24317` / `localhost:24318`
- Prometheus: `localhost:29090`

## Non-negotiable constraints
- Trading Core hot-path must not make synchronous DB calls.
- "Executed" commit-line is after WAL durable write only.
- Ledger is append-only; corrections only via reversal/adjustment.
- Every event must include `event_id`, `event_version`, `symbol`, `seq`, `occurred_at`, `correlation_id`, `causation_id`.
- WS must enforce backpressure and allow conflation for book/candle streams.

## Edge auth (G2)
Configure auth in env:
- `EDGE_API_SECRETS="key1:secret-with-min-16,key2:another-min-16"` (each secret min 16 chars)
- `EDGE_ALLOW_INSECURE_NO_AUTH=false` (default; when `EDGE_API_SECRETS` is empty, unsigned trading requests are rejected unless explicitly enabled for local smoke)
- `EDGE_AUTH_SKEW_SEC=30`
- `EDGE_REPLAY_TTL_SEC=120`
- `EDGE_RATE_LIMIT_PER_MINUTE=1000`
- `EDGE_PUBLIC_RATE_LIMIT_PER_MINUTE=2000` (public market REST, per-client IP)
- `EDGE_DISABLE_CORE=true` (optional: 코어 없이 마켓 조회/WS만 실행)
- `EDGE_SEED_MARKET_DATA=true` (default: server boot 시 샘플 마켓 데이터 자동 주입)
- `EDGE_ENABLE_SMOKE_ROUTES=false` (default; test scripts only set `true`)
- `EDGE_SESSION_TTL_HOURS=24`
- `EDGE_SESSION_MAX_PER_USER=8` (oldest session tokens are evicted when cap is exceeded)
- `EDGE_KAFKA_BROKERS=localhost:29092` (core trade event consume)
- `EDGE_KAFKA_TRADE_TOPIC=core.trade-events.v1`
- `EDGE_KAFKA_GROUP_ID=edge-trades-v1`
- `EDGE_KAFKA_START_OFFSET=first` (`first` default for no-commit catch-up, `last` optional)
- `EDGE_ORDER_RETENTION_MINUTES=1440` (terminal order record TTL in edge memory)
- `EDGE_ORDER_MAX_RECORDS=100000` (in-memory order map upper bound)
- `EDGE_ORDER_GC_INTERVAL_SEC=30` (order record GC cadence)
- `EDGE_WS_MAX_SUBSCRIPTIONS=64` (per connection)
- `EDGE_WS_COMMAND_RATE_LIMIT=240` (commands per window)
- `EDGE_WS_COMMAND_WINDOW_SEC=60`
- `EDGE_WS_PING_INTERVAL_SEC=20`
- `EDGE_WS_PONG_TIMEOUT_SEC=60`
- `EDGE_WS_READ_LIMIT_BYTES=1048576`
- `EDGE_WS_MAX_CONNS=20000` (global admission cap)
- `EDGE_WS_MAX_CONNS_PER_IP=500` (per-IP admission cap)
- `EDGE_WS_ALLOWED_ORIGINS=https://app.exchange.example,https://admin.exchange.example` (optional allowlist)
- `EDGE_POLICY_REQUIRE_SIGNED=false` (when `true`, startup fails unless policy signature verification succeeds)
- `EDGE_POLICY_FILE=policies/trading-policy.v1.json`
- `EDGE_POLICY_SIGNATURE_FILE=build/policy-smoke/trading-policy.v1.sig`
- `EDGE_POLICY_PUBLIC_KEY_FILE=build/policy-smoke/dev-public.pem`

`EDGE_DISABLE_CORE=true`에서는 주문 API가 `core_unavailable`로 거절됩니다.
주문/체결 플로우 테스트는 Trading Core 실행이 필요합니다.
`/readyz`는 DB/Redis 외에 다음 상태를 함께 검사합니다:
- `EDGE_DISABLE_CORE=false`일 때 core gRPC 연결 상태
- `EDGE_KAFKA_BROKERS` 설정 시 trade consumer 실행/최근 읽기 오류 상태

Request headers for trading endpoints:
- `X-API-KEY`
- `X-TS` (epoch ms)
- `X-SIGNATURE` (HMAC-SHA256 of `METHOD\nPATH\nX-TS\nBODY`)
- `Idempotency-Key` (POST/DELETE required)

Auth hardening notes:
- unknown `X-API-KEY` 요청도 client(IP) 단위 rate-limit가 적용되어 key enumeration 시도를 제한합니다.

## OTel config (I-0102)
Edge env:
- `EDGE_OTEL_ENDPOINT=localhost:24317`
- `EDGE_OTEL_INSECURE=true`
- `EDGE_OTEL_SERVICE_NAME=edge-gateway`
- `EDGE_OTEL_ENV=local`
- `EDGE_OTEL_SAMPLE_RATIO=1.0`

Ledger env:
- `LEDGER_OTEL_ENDPOINT=http://localhost:24318/v1/traces`
- `LEDGER_OTEL_SAMPLE_PROB=1.0`
- `LEDGER_RECONCILIATION_ENABLED=true`
- `LEDGER_RECONCILIATION_INTERVAL_MS=5000`
- `LEDGER_RECONCILIATION_LAG_THRESHOLD=10`
- `LEDGER_RECONCILIATION_STATE_STALE_MS=30000` (latest seq update freshness budget)
- `LEDGER_READY_REQUIRE_SETTLEMENT_CONSUMER=true` (`true`면 Kafka settlement consumer 미가동/일시정지 시 `/readyz`가 `503`)
- `LEDGER_ADMIN_TOKEN=` (optional; when set, `/v1/admin/**` and `/v1/balances` require `X-Admin-Token`)
- `LEDGER_RECONCILIATION_SAFETY_MODE=CANCEL_ONLY` (`SOFT_HALT`/`HARD_HALT` supported)
- `LEDGER_RECONCILIATION_AUTO_SWITCH=true`
- `LEDGER_RECONCILIATION_SAFETY_LATCH_ENABLED=true` (breach latched until manual release)
- `LEDGER_RECONCILIATION_LATCH_ALLOW_NEGATIVE=false` (stub smoke only: `true` 허용 가능)
- `LEDGER_RECONCILIATION_LATCH_RELEASE_REQUIRE_DUAL_APPROVAL=false` (`true`면 latch release 시 `approvedBy2` 추가 승인자 필수)
- `LEDGER_GUARD_AUTO_SWITCH=true` (`false` to keep invariant scheduler as monitor-only)
- `LEDGER_GUARD_SAFETY_MODE=CANCEL_ONLY`

Safety latch release contract:
- `POST /v1/admin/reconciliation/latch/{symbol}/release`
- request body: `approvedBy`, `reason`, `restoreSymbolMode`, and optional `approvedBy2`
- when `LEDGER_RECONCILIATION_LATCH_RELEASE_REQUIRE_DUAL_APPROVAL=true`, `approvedBy2` must be present and different from `approvedBy`
- release is allowed only when:
  - reconciliation is recovered (`lag==0`, no mismatch/threshold breach)
  - invariant check passes at release time

Reconciliation alert rule examples:
- `infra/observability/reconciliation-alert-rules.example.yml`
  - includes breach/stale/safety-trigger alerts and latch-release denied alerts

Reconciliation metrics (ledger `/metrics`):
- `reconciliation_lag_max`
- `reconciliation_breach_active`
- `reconciliation_alert_total`
- `reconciliation_mismatch_total`
- `reconciliation_stale_total`
- `reconciliation_safety_trigger_total`
- `reconciliation_safety_failure_total`
- `reconciliation_latch_release_attempt_total`
- `reconciliation_latch_release_success_total`
- `reconciliation_latch_release_denied_total`
- `reconciliation_latch_release_denied_reason_total{reason="..."}`
- `invariant_safety_trigger_total`
- `invariant_safety_failure_total`
- `reconciliation_gap_by_symbol{symbol="..."}`
- `reconciliation_age_ms_by_symbol{symbol="..."}`

Edge readiness/consumer metrics (`/metrics`):
- `edge_trade_consumer_running`
- `edge_trade_consumer_read_error_total`
- `edge_wallet_persist_error_total` (wallet persistence failures with in-memory rollback)

Ledger `/readyz` failure statuses:
- `db_unready`
- `settlement_consumer_unavailable`
- `settlement_consumer_not_running`
- `settlement_consumer_paused`
