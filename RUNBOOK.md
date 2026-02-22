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

### 4.1 Crash recovery drill
Purpose:
- verify Trading Core `kill -9` recovery from WAL is deterministic (`state_hash` continuity)
- verify Ledger `kill -9` recovery resumes Kafka consumption without double-apply

Command:
- Full drill: `./scripts/chaos_replay.sh`
- Core only: `./scripts/chaos/core_kill_recover.sh`
- Ledger only: `./scripts/chaos/ledger_kill_recover.sh`
- Redpanda bounce: `./scripts/chaos/redpanda_broker_bounce.sh`

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
