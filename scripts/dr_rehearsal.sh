#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="docker compose -f $ROOT_DIR/infra/compose/docker-compose.yml"
OUT_DIR="$ROOT_DIR/build/dr"
DUMP_FILE="$OUT_DIR/dr_source.sql"
REPORT_FILE="$OUT_DIR/dr-report.json"

mkdir -p "$OUT_DIR"

echo "dr_rehearsal_start=true"
$COMPOSE up -d postgres >/dev/null

$COMPOSE exec -T postgres psql -U exchange -d postgres -c "DROP DATABASE IF EXISTS dr_source WITH (FORCE);" >/dev/null
$COMPOSE exec -T postgres psql -U exchange -d postgres -c "CREATE DATABASE dr_source;" >/dev/null

$COMPOSE exec -T postgres psql -U exchange -d dr_source < "$ROOT_DIR/services/ledger-service/src/main/resources/db/migration/V1__ledger_schema.sql" >/dev/null

# Seed minimal deterministic ledger dataset.
$COMPOSE exec -T postgres psql -U exchange -d dr_source <<'SQL' >/dev/null
INSERT INTO accounts(account_id, user_id, currency, account_kind) VALUES
  ('user:alice:USD:AVAILABLE', 'alice', 'USD', 'AVAILABLE'),
  ('system:treasury:USD:AVAILABLE', 'system', 'USD', 'AVAILABLE')
ON CONFLICT DO NOTHING;

INSERT INTO ledger_entries(entry_id, reference_type, reference_id, entry_kind, symbol, engine_seq, occurred_at, correlation_id, causation_id)
VALUES
  ('le_seed_1', 'ADJUSTMENT', 'seed-1', 'MANUAL_ADJUSTMENT', 'USD-USD', 1, now(), 'corr-1', 'cause-1')
ON CONFLICT DO NOTHING;

INSERT INTO ledger_postings(posting_id, entry_id, account_id, currency, amount, is_debit)
VALUES
  ('lp_seed_1', 'le_seed_1', 'user:alice:USD:AVAILABLE', 'USD', 1000, true),
  ('lp_seed_2', 'le_seed_1', 'system:treasury:USD:AVAILABLE', 'USD', 1000, false)
ON CONFLICT DO NOTHING;

INSERT INTO account_balances(account_id, currency, balance, updated_at)
VALUES
  ('user:alice:USD:AVAILABLE', 'USD', 1000, now()),
  ('system:treasury:USD:AVAILABLE', 'USD', -1000, now())
ON CONFLICT (account_id, currency) DO UPDATE SET balance = excluded.balance, updated_at = excluded.updated_at;
SQL

BACKUP_START_MS="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

$COMPOSE exec -T postgres pg_dump -U exchange -d dr_source > "$DUMP_FILE"

$COMPOSE exec -T postgres psql -U exchange -d postgres -c "DROP DATABASE IF EXISTS dr_restore WITH (FORCE);" >/dev/null
$COMPOSE exec -T postgres psql -U exchange -d postgres -c "CREATE DATABASE dr_restore;" >/dev/null

$COMPOSE exec -T postgres psql -U exchange -d dr_restore < "$DUMP_FILE" >/dev/null

BACKUP_END_MS="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

RESTORE_TIME_MS="$((BACKUP_END_MS - BACKUP_START_MS))"

REPLAY_START_MS="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

$COMPOSE exec -T postgres psql -U exchange -d dr_restore -c "TRUNCATE TABLE account_balances;" >/dev/null
$COMPOSE exec -T postgres psql -U exchange -d dr_restore <<'SQL' >/dev/null
INSERT INTO account_balances(account_id, currency, balance, updated_at)
SELECT account_id, currency, SUM(CASE WHEN is_debit THEN amount ELSE -amount END), now()
FROM ledger_postings
GROUP BY account_id, currency;
SQL

REPLAY_END_MS="$(python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
)"

REPLAY_TIME_MS="$((REPLAY_END_MS - REPLAY_START_MS))"

SOURCE_ENTRY_COUNT="$($COMPOSE exec -T postgres psql -U exchange -d dr_source -tAc "SELECT COUNT(*) FROM ledger_entries;" | tr -d '[:space:]')"
RESTORE_ENTRY_COUNT="$($COMPOSE exec -T postgres psql -U exchange -d dr_restore -tAc "SELECT COUNT(*) FROM ledger_entries;" | tr -d '[:space:]')"
SOURCE_POSTING_COUNT="$($COMPOSE exec -T postgres psql -U exchange -d dr_source -tAc "SELECT COUNT(*) FROM ledger_postings;" | tr -d '[:space:]')"
RESTORE_POSTING_COUNT="$($COMPOSE exec -T postgres psql -U exchange -d dr_restore -tAc "SELECT COUNT(*) FROM ledger_postings;" | tr -d '[:space:]')"

INVARIANT_VIOLATIONS="$($COMPOSE exec -T postgres psql -U exchange -d dr_restore -tAc \
  "SELECT COUNT(*) FROM (SELECT entry_id, currency, SUM(CASE WHEN is_debit THEN amount ELSE -amount END) AS signed_sum FROM ledger_postings GROUP BY entry_id, currency HAVING SUM(CASE WHEN is_debit THEN amount ELSE -amount END) <> 0) t;" | tr -d '[:space:]')"

cat > "$REPORT_FILE" <<JSON
{
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "restore_time_ms": $RESTORE_TIME_MS,
  "replay_time_ms": $REPLAY_TIME_MS,
  "source_entry_count": $SOURCE_ENTRY_COUNT,
  "restore_entry_count": $RESTORE_ENTRY_COUNT,
  "source_posting_count": $SOURCE_POSTING_COUNT,
  "restore_posting_count": $RESTORE_POSTING_COUNT,
  "invariant_violations": $INVARIANT_VIOLATIONS,
  "rpo_target": "0",
  "rto_target": "1800000"
}
JSON

if [[ "$SOURCE_ENTRY_COUNT" != "$RESTORE_ENTRY_COUNT" || "$SOURCE_POSTING_COUNT" != "$RESTORE_POSTING_COUNT" ]]; then
  echo "dr_rehearsal_failed=row_count_mismatch"
  cat "$REPORT_FILE"
  exit 1
fi

if [[ "$INVARIANT_VIOLATIONS" != "0" ]]; then
  echo "dr_rehearsal_failed=invariant_violation"
  cat "$REPORT_FILE"
  exit 1
fi

echo "dr_rehearsal_success=true"
cat "$REPORT_FILE"
