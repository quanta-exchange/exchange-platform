# RUNBOOK.md — Spot Exchange (Ops Playbooks)

> This runbook assumes oncall rotation and production monitoring is live.
> All actions must be audited. Prefer safety over availability when money is at risk.

---

## 1) Severity definitions
- **SEV1**: potential loss of funds / ledger invariant violation / split‑brain suspected / signing compromise
- **SEV2**: trading unavailable for many users / major market data outage / settlement lag beyond policy
- **SEV3**: partial degradation / elevated latency / minor data gaps

---

## 2) Core dashboards (must exist)
- Trading API p50/p99 latency, error rate
- Engine:
  - queue depth, loop p99, WAL fsync p99, CPU, GC/alloc(should be N/A for Rust)
  - per‑symbol TPS and seq rate
- Kafka:
  - produce/consume lag, broker health
- Ledger:
  - settlement lag, consumer lag, DB tx errors, invariants check results
- WS:
  - connected clients, outbound rate, drop/close counts, backlog per conn
- Edge auth:
  - auth_fail_total{reason}, replay_detect_total, per-key rate-limit drops

---

## 3) Incident playbooks

### 3.1 Ledger invariant violation (SEV1)
**Signal**
- `invariant_violation_total > 0`
- reconciliation mismatch (engine_seq vs ledger_seq) persists

**Immediate actions**
1) **HALT withdrawals** (mandatory)
2) Set affected symbols to `CANCEL_ONLY` (or global SOFT_HALT if unknown scope)
3) Create forensic bundle:
   - WAL segments + snapshots + kafka offsets + ledger entry range + configs

**Diagnosis**
- Identify missing/double postings (unique constraint hits? consumer retries?)
- Check latest deployments and config changes
- Validate integrity roots (if enabled)

**Recovery**
- If safe: replay settlement from last good offset using idempotency keys
- If corruption: stop trading, rebuild balances from ledger, apply correction entries
- reconciliation safety latch is manual-release only:
  - `POST /v1/admin/reconciliation/latch/{symbol}/release` (requires operator approval reason)
- Postmortem required

---

### 3.2 Settlement lag spike (SEV2 → SEV1 if prolonged)
**Signal**
- settlement lag p99 > T2 (throttle), > T3 (halt) as per policy

**Immediate actions**
1) Verify Postgres health: connections, locks, disk IO, replication
2) Verify Kafka consumer lag and errors
3) Apply policy:
   - throttle new orders for affected symbols
   - if > T3, set `SOFT_HALT`

**Recovery**
- Scale ledger consumers (if horizontally safe)
- Reduce nonessential workloads (analytics sinks)
- If DB overloaded: increase resources or fail over (if tested)

---

### 3.3 Split‑brain suspected (SEV1)
**Signal**
- duplicate seq detected
- divergent state hashes from standby
- conflicting leadership/fencing token anomalies

**Immediate actions**
1) Set affected symbol(s) to `HARD_HALT`
2) Confirm only one leader holds lease + fencing token
3) Preserve evidence (WAL + lease logs)

**Recovery**
- Choose authoritative leader:
  - the one with highest durable seq and valid fencing token
- Restart/replace the other node; resync from snapshot+WAL
- Resume in `CANCEL_ONLY` first, then NORMAL after validation

Gate G1 operational check:
- if stale leader rejection appears (`FENCING_TOKEN`), verify lease/token source first before manual recovery actions.

---

### 3.4 WS fan‑out overload (SEV2/SEV3)
**Signal**
- ws_close_total{SLOW_CONSUMER} rising
- edge CPU high, outbound queue growth, publish lag

**Immediate actions**
1) Enable aggressive conflation for book/candle updates
   - include ticker channel conflation in overload mode
2) Lower book depth default (e.g., 20)
3) Increase rate limits for subscription operations (protect server)

**Recovery**
- Scale edge-gateway replicas
- Add regional WS shards
- Validate that trades channel is not being dropped

---

### 3.5 Kafka/Redpanda outage (SEV2)
**Signal**
- producer errors, broker unavailable, consumer lag skyrockets

**Immediate actions**
1) Keep Trading Core running (WAL/outbox)
2) Degrade WS: inform clients, rely on snapshots after recovery
3) Pause noncritical consumers (analytics)

**Recovery**
- Restore brokers, verify ISR / partitions healthy
- Resume outbox publishing; watch for backlog and throttling
- Validate ledger consumer catches up (idempotent)

---

### 3.6 Postgres failover / corruption (SEV1/SEV2)
**Immediate actions**
1) Freeze withdrawals
2) Depending on impact: `CANCEL_ONLY` or `SOFT_HALT`
3) Verify backups + PITR readiness

**Recovery**
- Failover to standby if configured and rehearsed
- If recovery required: restore from backup/PITR, then replay settlement from Kafka
- Rebuild balances MV; run reconciliation

---

## 4) Routine operations
- Daily:
  - reconciliation summary, invariants check, settlement lag report
- Weekly:
  - restore rehearsal (staging), chaos drills (staging)
- Monthly:
  - DR exercise, access review (RBAC/MFA/JIT)

### 4.0 Runbook-as-code entrypoints
- Reconciliation lag drill: `./runbooks/lag_spike.sh`
- WS drop/slow-consumer drill: `./runbooks/ws_drop_spike.sh`
- WS resume-gap drill: `./runbooks/ws_resume_gap_spike.sh`
- Load regression drill: `./runbooks/load_regression.sh`
- Crash recovery drill: `./runbooks/crash_recovery.sh`
- Startup guardrails drill: `./runbooks/startup_guardrails.sh`
- Game-day anomaly drill: `./runbooks/game_day_anomaly.sh`
- Audit-chain tamper drill: `./runbooks/audit_chain_tamper.sh`
- Change workflow drill: `./runbooks/change_workflow.sh`
- Budget failure drill: `./runbooks/budget_failure.sh`
- Exactly-once million failure drill: `./runbooks/exactly_once_million_failure.sh`
- Mapping integrity failure drill: `./runbooks/mapping_integrity_failure.sh`
- Idempotency+latch failure drill: `./runbooks/idempotency_latch_failure.sh`
- Policy signature drill: `./runbooks/policy_signature.sh`
- Policy tamper drill: `./runbooks/policy_tamper.sh`
- Kafka network partition drill: `./runbooks/network_partition.sh`
- Redpanda broker bounce drill: `./runbooks/redpanda_broker_bounce.sh`
- Adversarial reliability drill: `./runbooks/adversarial_reliability.sh`
- Shared verification bundle: `./scripts/verification_factory.sh`
  - with startup drill: `./scripts/verification_factory.sh --run-startup-guardrails`
  - with change workflow drill: `./scripts/verification_factory.sh --run-change-workflow`
  - with policy signature drill: `./scripts/verification_factory.sh --run-policy-signature`
  - with policy tamper drill: `./scripts/verification_factory.sh --run-policy-tamper`
  - with network partition drill: `./scripts/verification_factory.sh --run-network-partition`
  - with redpanda bounce drill: `./scripts/verification_factory.sh --run-redpanda-bounce`
  - with exactly-once million runbook: `./scripts/verification_factory.sh --run-exactly-once-runbook`
  - with mapping integrity runbook: `./scripts/verification_factory.sh --run-mapping-integrity-runbook`
  - with idempotency+latch runbook: `./scripts/verification_factory.sh --run-idempotency-latch-runbook`
  - with determinism proof: `./scripts/verification_factory.sh --run-determinism`
  - with exactly-once million proof: `./scripts/verification_factory.sh --run-exactly-once-million`
  - with adversarial drill: `./scripts/verification_factory.sh --run-adversarial`
- Audit tamper-evidence verify: `./scripts/verify_audit_chain.sh --require-events`
- Change audit-chain verify: `./scripts/verify_change_audit_chain.sh --require-events`
- PII log scan gate: `./scripts/pii_log_scan.sh`
- Anomaly detector probe: `./scripts/anomaly_detector.sh`
- Anomaly webhook smoke: `./scripts/anomaly_detector_smoke.sh`
- RBAC SoD check: `./scripts/rbac_sod_check.sh`
- Safety budget freshness proof: `./scripts/prove_budget_freshness.sh`
- Controls freshness proof: `./scripts/prove_controls_freshness.sh`
- Change workflow:
  - create proposal: `./scripts/change_proposal.sh ...`
  - record approval: `./scripts/change_approve.sh ...`
  - apply change (with verification): `./scripts/apply_change.sh ...`
- Break-glass workflow:
  - enable: `./scripts/break_glass.sh enable --ttl-sec 900 --actor <oncall> --reason <incident>`
  - status: `./scripts/break_glass.sh status`
  - disable: `./scripts/break_glass.sh disable --actor <oncall> --reason <resolved>`
- Access review report: `./scripts/access_review.sh`

### 4.1 Crash recovery drill
Purpose:
- verify Trading Core `kill -9` recovery from WAL is deterministic (`state_hash` continuity)
- verify Ledger `kill -9` recovery resumes Kafka consumption without double-apply

Command:
- Full drill: `./scripts/chaos_replay.sh`
- Core only: `./scripts/chaos/core_kill_recover.sh`
- Ledger only: `./scripts/chaos/ledger_kill_recover.sh`
- Redpanda bounce: `./scripts/chaos/redpanda_broker_bounce.sh`
- Redpanda network partition: `./scripts/chaos/network_partition.sh`

Drill flow:
1) Start local stack (Postgres + Redpanda + Core + Edge + Ledger)
2) Create orders to generate `TradeExecuted` events
3) `kill -9` Trading Core, restart with same WAL/outbox
4) Compare pre-crash WAL hash vs post-restart recovered hash
5) Continue trading, then `kill -9` Ledger
6) Produce trades while Ledger is down
7) Restart Ledger with same consumer group and verify catch-up

Success criteria:
- output includes `chaos_replay_success=true`
- `core_recovery_hash` matches pre-crash WAL hash
- `ledger_duplicate_rows=0`
- `ledger_trade_rows` equals generated trade count
- post-recovery invariant check returns `ok=true`
  - stub trade mode에서는 `invariants_warning=negative_balances_present_under_stub_mode`가 함께 출력될 수 있음

Related snapshot rehearsal:
- `./scripts/snapshot_verify.sh`
  - optional `--snapshot-uri <http(s)|file://...>` for remote retrieval
  - verifies checksum (`--sha256-file` or `<snapshot>.sha256`) when available
  - executes snapshot + WAL restore rehearsal and emits:
    - `snapshot_verify_ok=true`
    - `snapshot_verify_latest=build/snapshot/snapshot-verify-latest.json`

Runbook-as-code shortcut:
- `./runbooks/crash_recovery.sh`
  - defaults `CHAOS_SKIP_LEDGER_ASSERTS=true` for fast drills
  - set `CHAOS_SKIP_LEDGER_ASSERTS=false` for strict ledger row-count assertions

### 4.2 WS resume-gap drill
Purpose:
- verify trade replay-gap signaling (`Missed`/`Snapshot`) and `ws_resume_gaps` metric increments are observable
- ensure WS resume safety budget gate remains green under controlled gap scenario

Command:
- `./runbooks/ws_resume_gap_spike.sh`

Success criteria:
- output includes `runbook_ws_resume_gap_spike_ok=true`
- runbook output contains:
  - `ws-resume-smoke.json` (`gap_recovery.result_type`, `metrics.ws_resume_gaps`)
  - `safety-budget-*.json` with `wsResume` check pass
  - `status-before.json` / `status-after.json`

### 4.3 Load regression drill
Purpose:
- validate staged load profiles (`load-smoke`, `load-10k`, `load-50k`) in one pass
- capture consolidated pass/fail report and budget compliance evidence after change/deploy

Command:
- `./runbooks/load_regression.sh`
- gateway-only dry-run: `RUNBOOK_ALLOW_BUDGET_FAIL=true ./runbooks/load_regression.sh`

Success criteria:
- output includes `runbook_load_regression_ok=true`
- runbook output contains:
  - `load-all-*.json` and `load-all-latest.json`
  - `safety-budget-*.json`
  - `status-before.json` / `status-after.json`

### 4.4 Startup guardrails drill
Purpose:
- validate production fail-closed startup guardrails remain enforced for Edge, Trading Core, Ledger
- catch unsafe config drift (no admin token, loopback brokers/core endpoints, latch approval disabled)

Command:
- `./runbooks/startup_guardrails.sh`
- local fallback when rust toolchain cannot build `rdkafka-sys`: `RUNBOOK_ALLOW_CORE_FAIL=true ./runbooks/startup_guardrails.sh`

Success criteria:
- output includes `runbook_startup_guardrails_ok=true`
- runbook output contains:
  - `edge_guardrails_tests_ok=true`
  - `ledger_guardrails_tests_ok=true`
  - `core_guardrails_ok=true` (or explicit skip reason when `RUNBOOK_ALLOW_CORE_FAIL=true`)
  - `status-before.json` / `status-after.json`

### 4.5 Game-day anomaly drill
Purpose:
- anomaly detector 경보/권고 액션/증거 산출 흐름을 강제 주입으로 점검
- webhook 알림 경로와 before/after 상태 스냅샷을 함께 확인

Command:
- `./runbooks/game_day_anomaly.sh`
- webhook 포함: `WEBHOOK_URL=https://example.internal/webhook ./runbooks/game_day_anomaly.sh`

Success criteria:
- output includes `runbook_game_day_anomaly_ok=true`
- runbook output contains:
  - `anomaly-detector-*.json`
  - `safety-budget-*.json`
  - `status-before.json` / `status-after.json`

### 4.6 Audit-chain tamper drill
Purpose:
- break-glass 감사 로그 변조를 복사본에서 주입해 hash-chain 검증기가 실패를 정확히 감지하는지 확인

Command:
- `./runbooks/audit_chain_tamper.sh`

Success criteria:
- output includes `runbook_audit_tamper_ok=true`
- runbook output contains:
  - `audit-chain-tamper-summary.json` (`baseline_ok=true`, `tamper_detected=true`)
  - `status-before.json` / `status-after.json`

### 4.7 Change workflow drill
Purpose:
- 변경관리 흐름(proposal -> 2인 승인 -> apply -> change audit-chain verify)을 정기적으로 점검
- 운영 승인 통제와 변경 이력 tamper-evidence를 단일 실행으로 확인

Command:
- `./runbooks/change_workflow.sh`
- full verification apply: `RUNBOOK_SKIP_VERIFICATION=false ./runbooks/change_workflow.sh`

Success criteria:
- output includes `runbook_change_workflow_ok=true`
- runbook output contains:
  - `change-workflow-summary.json`
  - `verify-change-audit-chain-*.json`
  - `status-before.json` / `status-after.json`

### 4.8 Safety budget failure drill
Purpose:
- safety budget 위반 원인을 빠르게 진단하고 권고 액션을 자동 생성
- 온콜이 `release_gate` 실패 원인을 즉시 분류하도록 지원

Command:
- `./runbooks/budget_failure.sh`

Success criteria:
- output includes `runbook_budget_failure_ok=true`
- runbook output contains:
  - `budget-failure-summary.json` (`budget_ok`, `violation_count`, `recommended_action`)
  - `status-before.json` / `status-after.json`

### 4.9 Adversarial reliability drill
Purpose:
- 적대적 입력 시나리오(policy/ws-resume/candle/snapshot/exactly-once)를 단일 번들로 재검증
- 실패 시 권고 액션을 자동 산출하고 safety budget 상태를 함께 확인

Command:
- `./runbooks/adversarial_reliability.sh`
- 실패 허용 진단 모드: `RUNBOOK_ALLOW_ADVERSARIAL_FAIL=true ./runbooks/adversarial_reliability.sh`

Success criteria:
- output includes `runbook_adversarial_reliability_ok=true`
- runbook output contains:
  - `adversarial-reliability-summary.json` (`adversarial_ok`, `failed_step_count`, `recommended_action`)
  - `adversarial/adversarial-tests-latest.json`
  - `status-before.json` / `status-after.json`

### 4.10 Policy signature drill
Purpose:
- 정책 서명/검증 파이프라인이 운영 환경에서도 계속 실행 가능한지 정기 점검
- 정책 증거와 safety budget 상태를 함께 확인

Command:
- `./runbooks/policy_signature.sh`
- 실패 허용 진단 모드: `RUNBOOK_ALLOW_POLICY_FAIL=true ./runbooks/policy_signature.sh`

Success criteria:
- output includes `runbook_policy_signature_ok=true`
- runbook output contains:
  - `policy-signature-summary.json` (`policy_ok`, `budget_ok`, `recommended_action`)
  - `policy-smoke/policy-smoke-latest.json`
  - `status-before.json` / `status-after.json`

### 4.11 Policy tamper drill
Purpose:
- 정책 파일 변조가 서명 검증에서 실제로 차단되는지 정기 점검
- tamper detection 증거와 safety budget 상태를 함께 확인

Command:
- `./runbooks/policy_tamper.sh`
- 실패 허용 진단 모드: `RUNBOOK_ALLOW_POLICY_TAMPER_FAIL=true ./runbooks/policy_tamper.sh`

Success criteria:
- output includes `runbook_policy_tamper_ok=true`
- runbook output contains:
  - `policy-tamper-summary.json` (`policy_tamper_ok`, `tamper_detected`, `recommended_action`)
  - `policy/prove-policy-tamper-latest.json`
  - `status-before.json` / `status-after.json`

### 4.12 Kafka network partition drill
Purpose:
- broker 경로 단절(네트워크 분리/일시 정지) 시 연결 손실 감지와 복구 후 재전송 경로를 점검
- 분리 중 endpoint 비가용성과 복구 후 produce/consume 정상화를 증거로 남김

Command:
- `./runbooks/network_partition.sh`
- 실패 허용 진단 모드: `RUNBOOK_ALLOW_NETWORK_PARTITION_FAIL=true ./runbooks/network_partition.sh`

Success criteria:
- output includes `runbook_network_partition_ok=true`
- runbook output contains:
  - `network-partition-summary.json` (`network_partition_ok`, `during_partition_broker_reachable`, `recommended_action`)
  - `chaos/network-partition-latest.json`
  - `status-before.json` / `status-after.json`

### 4.13 Redpanda broker bounce drill
Purpose:
- broker stop/restart 시점의 일시 비가용성과 복구 후 consume 연속성을 점검
- 복구 경로를 runbook evidence로 남기고 safety budget 반영 상태를 함께 확인

Command:
- `./runbooks/redpanda_broker_bounce.sh`
- 실패 허용 진단 모드: `RUNBOOK_ALLOW_REDPANDA_BOUNCE_FAIL=true ./runbooks/redpanda_broker_bounce.sh`

Success criteria:
- output includes `runbook_redpanda_broker_bounce_ok=true`
- runbook output contains:
  - `redpanda-broker-bounce-summary.json` (`redpanda_broker_bounce_ok`, `during_stop_broker_reachable`, `recommended_action`)
  - `chaos/redpanda-broker-bounce-latest.json`
  - `status-before.json` / `status-after.json`

---

## 5) Local smoke (Gate G0)

### Purpose
- Verify minimum end-to-end path on local stack:
  - order accepted
  - trade settlement append in Postgres
  - WS trade/candle updates delivered

### Steps
1) Bring infra up:
   - `docker compose -f infra/compose/docker-compose.yml up -d`
2) Run smoke:
   - `./scripts/smoke_g0.sh`
3) Validate outputs:
   - script prints `smoke_g0_success=true`
   - `ws_events` contains both `TradeExecuted` and `CandleUpdated`

### Failure handling
- If readiness fails:
  - inspect `/tmp/edge-gateway-smoke.log`
  - check DB reachability: `docker compose -f infra/compose/docker-compose.yml exec -T postgres pg_isready -U exchange -d exchange`
- If settlement append fails:
  - inspect table: `docker compose -f infra/compose/docker-compose.yml exec -T postgres psql -U exchange -d exchange -c 'SELECT * FROM smoke_ledger_entries ORDER BY id DESC LIMIT 20;'`
- If WS event missing:
  - check `/tmp/ws-events-smoke.log`
  - verify `POST /v1/smoke/trades` returned `status=settled`

### 5.1 Gate G3 smoke (ledger safety path)
Purpose:
- verify reserve + settlement append into ledger tables and WS updates in same local run

Steps:
1) Bring infra up:
   - `docker compose -f infra/compose/docker-compose.yml up -d`
2) Run G3 smoke:
   - `./scripts/smoke_g3.sh`
3) Validate outputs:
   - script prints `smoke_g3_success=true`
   - ledger query returns one trade entry for `trade-smoke-g3-1`
   - `ws_events` contains both `TradeExecuted` and `CandleUpdated`

Failure handling:
- If ledger readiness fails:
  - inspect `/tmp/ledger-service-smoke-g3.log`
- If settlement append fails:
  - inspect table:
    - `docker compose -f infra/compose/docker-compose.yml exec -T postgres psql -U exchange -d exchange -c "SELECT reference_type, reference_id, entry_kind, symbol, engine_seq FROM ledger_entries ORDER BY created_at DESC LIMIT 20;"`
- If correction/invariant checks are noisy during incident:
  - keep guard enabled, tune thresholds/config only through audited change

---

## 6) Emergency controls (Admin)
- `SetSymbolMode(symbol, CANCEL_ONLY|SOFT_HALT|HARD_HALT)`
- `CancelAll(symbol)`
- `WithdrawalsHalt(on/off)` (if custody is enabled later)
- All actions must be audited with reason + ticket id

---

## 7) Load Harness (I-0105)
Purpose:
- detect order/WS regressions before release

Command:
- `./scripts/load_smoke.sh`

Outputs:
- `build/load/load-smoke.json`
- key fields: `order_p99_ms`, `order_error_rate`, `order_tps`, `ws_messages`

Response:
- if threshold violation: block release and investigate perf regression before retry

---

## 8) DR Rehearsal (I-0106)
Purpose:
- verify backup/restore and replay timings against RTO/RPO targets

Command:
- `./scripts/dr_rehearsal.sh`

Outputs:
- `build/dr/dr-report.json`
- key fields: `restore_time_ms`, `replay_time_ms`, `invariant_violations`

Response:
- any failure or invariant violation blocks launch

---

## 9) Access Control (I-0107)
JIT grant generation:
- `./scripts/jit_access_grant.sh <user> <ticket_id> <reason> <duration_minutes>`

Validation:
- generated binding must include `ticket-id`, `reason`, `expires-at` annotations
- all production admin actions require audit trail

Unauthorized attempt playbook:
1) revoke active JIT grants
2) rotate potentially exposed credentials
3) review audit logs and incident timeline

---

## 10) Safety Case (I-0108)
Command:
- `make safety-case`

Output bundle:
- `build/safety-case/manifest.json`
- `build/safety-case/safety-case-<commit>.tar.gz`
- `build/safety-case/safety-case-<commit>.tar.gz.sha256`

Gate policy:
- if safety-case generation fails or evidence is missing, release is blocked
