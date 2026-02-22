package com.quanta.exchange.ledger.repo

import com.quanta.exchange.ledger.core.CorrectionRequest
import com.quanta.exchange.ledger.core.InvariantCheckResult
import com.quanta.exchange.ledger.core.LedgerEntryCommand
import com.quanta.exchange.ledger.core.LedgerPostingCommand
import com.quanta.exchange.ledger.core.ReconciliationEvaluation
import com.quanta.exchange.ledger.core.ReconciliationHistoryPoint
import com.quanta.exchange.ledger.core.ReconciliationSafetyState
import com.quanta.exchange.ledger.core.ReconciliationStatus
import com.quanta.exchange.ledger.core.TradeLookup
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional
import java.sql.ResultSet
import java.time.Instant
import java.util.UUID

@Repository
class LedgerRepository(
    private val jdbc: JdbcTemplate,
) {
    @Transactional
    fun appendEntry(command: LedgerEntryCommand): Boolean {
        if (!isDoubleEntry(command)) {
            throw IllegalArgumentException("entry is not balanced per currency")
        }

        try {
            jdbc.update(
                """
                INSERT INTO ledger_entries(
                    entry_id, reference_type, reference_id, entry_kind,
                    symbol, engine_seq, occurred_at, correlation_id, causation_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                command.entryId,
                command.referenceType,
                command.referenceId,
                command.entryKind,
                command.symbol,
                command.engineSeq,
                java.sql.Timestamp.from(command.occurredAt),
                command.correlationId,
                command.causationId,
            )
        } catch (ex: DataIntegrityViolationException) {
            if (isUniqueViolation(ex)) {
                return false
            }
            throw ex
        }

        command.postings.forEach { posting ->
            ensureAccount(posting.accountId, posting.currency)
            val postingId = UUID.randomUUID().toString()
            jdbc.update(
                """
                INSERT INTO ledger_postings(posting_id, entry_id, account_id, currency, amount, is_debit)
                VALUES (?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                postingId,
                command.entryId,
                posting.accountId,
                posting.currency,
                posting.amount,
                posting.isDebit,
            )

            val delta = if (posting.isDebit) posting.amount else -posting.amount
            applyBalanceDelta(posting.accountId, posting.currency, delta)
        }

        return true
    }

    fun appendDlq(tradeId: String, reason: String, payload: String) {
        jdbc.update(
            "INSERT INTO settlement_dlq(trade_id, reason, payload) VALUES (?, ?, ?)",
            tradeId,
            reason,
            payload,
        )
    }

    fun dlqCount(): Long {
        return jdbc.queryForObject("SELECT COUNT(*) FROM settlement_dlq", Long::class.java) ?: 0L
    }

    fun updateEngineSeq(symbol: String, seq: Long) {
        val updated = jdbc.update(
            """
            UPDATE reconciliation_state
            SET last_engine_seq = CASE WHEN last_engine_seq > ? THEN last_engine_seq ELSE ? END,
                updated_at = now()
            WHERE symbol = ?
            """.trimIndent(),
            seq,
            seq,
            symbol,
        )
        if (updated == 0) {
            try {
                jdbc.update(
                    """
                    INSERT INTO reconciliation_state(symbol, last_engine_seq, last_settled_seq, updated_at)
                    VALUES (?, ?, 0, now())
                    """.trimIndent(),
                    symbol,
                    seq,
                )
            } catch (ex: DataIntegrityViolationException) {
                if (isUniqueViolation(ex)) {
                    updateEngineSeq(symbol, seq)
                } else {
                    throw ex
                }
            }
        }
    }

    fun updateSettledSeq(symbol: String, seq: Long) {
        val updated = jdbc.update(
            """
            UPDATE reconciliation_state
            SET last_settled_seq = CASE WHEN last_settled_seq > ? THEN last_settled_seq ELSE ? END,
                updated_at = now()
            WHERE symbol = ?
            """.trimIndent(),
            seq,
            seq,
            symbol,
        )
        if (updated == 0) {
            try {
                jdbc.update(
                    """
                    INSERT INTO reconciliation_state(symbol, last_engine_seq, last_settled_seq, updated_at)
                    VALUES (?, 0, ?, now())
                    """.trimIndent(),
                    symbol,
                    seq,
                )
            } catch (ex: DataIntegrityViolationException) {
                if (isUniqueViolation(ex)) {
                    updateSettledSeq(symbol, seq)
                } else {
                    throw ex
                }
            }
        }
    }

    fun reconciliation(symbol: String): ReconciliationStatus {
        val rows = jdbc.query(
            """
            SELECT symbol, last_engine_seq, last_settled_seq, updated_at
            FROM reconciliation_state
            WHERE symbol = ?
            """.trimIndent(),
            { rs, _ ->
                val updatedAt = rs.getTimestamp("updated_at")?.toInstant()
                ReconciliationStatus(
                    symbol = rs.getString("symbol"),
                    lastEngineSeq = rs.getLong("last_engine_seq"),
                    lastSettledSeq = rs.getLong("last_settled_seq"),
                    gap = rs.getLong("last_engine_seq") - rs.getLong("last_settled_seq"),
                    updatedAt = updatedAt,
                )
            },
            symbol,
        )
        return rows.firstOrNull() ?: ReconciliationStatus(symbol, 0, 0, 0, null)
    }

    fun reconciliationAll(): List<ReconciliationStatus> {
        return jdbc.query(
            """
            SELECT symbol, last_engine_seq, last_settled_seq, updated_at
            FROM reconciliation_state
            ORDER BY symbol ASC
            """.trimIndent(),
            { rs, _ ->
                toReconciliationStatus(rs.getString("symbol"), rs.getLong("last_engine_seq"), rs.getLong("last_settled_seq"), rs.getTimestamp("updated_at"))
            },
        )
    }

    fun trackedSymbols(): List<String> {
        return jdbc.query(
            """
            SELECT symbol FROM reconciliation_state
            UNION
            SELECT DISTINCT symbol FROM ledger_entries
            ORDER BY symbol ASC
            """.trimIndent(),
            { rs, _ -> rs.getString("symbol") },
        )
    }

    fun recordReconciliationHistory(evaluation: ReconciliationEvaluation) {
        jdbc.update(
            """
            INSERT INTO reconciliation_history(
                symbol, last_engine_seq, last_settled_seq, lag,
                mismatch, threshold, breached, safety_mode,
                safety_action_taken, reason, checked_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """.trimIndent(),
            evaluation.symbol,
            evaluation.lastEngineSeq,
            evaluation.lastSettledSeq,
            evaluation.lag,
            evaluation.mismatch,
            evaluation.threshold,
            evaluation.breached,
            evaluation.safetyMode.name,
            evaluation.safetyActionTaken,
            evaluation.reason,
            java.sql.Timestamp.from(evaluation.checkedAt),
        )
    }

    fun reconciliationHistory(limit: Int): List<ReconciliationHistoryPoint> {
        val clamped = limit.coerceIn(1, 500)
        return jdbc.query(
            """
            SELECT id, symbol, last_engine_seq, last_settled_seq, lag,
                   mismatch, threshold, breached, safety_mode,
                   safety_action_taken, reason, checked_at
            FROM reconciliation_history
            ORDER BY checked_at DESC, id DESC
            LIMIT $clamped
            """.trimIndent(),
            { rs, _ ->
                ReconciliationHistoryPoint(
                    id = rs.getLong("id"),
                    symbol = rs.getString("symbol"),
                    lastEngineSeq = rs.getLong("last_engine_seq"),
                    lastSettledSeq = rs.getLong("last_settled_seq"),
                    lag = rs.getLong("lag"),
                    mismatch = rs.getBoolean("mismatch"),
                    threshold = rs.getLong("threshold"),
                    breached = rs.getBoolean("breached"),
                    safetyMode = rs.getString("safety_mode"),
                    safetyActionTaken = rs.getBoolean("safety_action_taken"),
                    reason = rs.getString("reason"),
                    checkedAt = rs.getTimestamp("checked_at").toInstant(),
                )
            },
        )
    }

    fun reconciliationSafetyState(symbol: String): ReconciliationSafetyState? {
        val rows = jdbc.query(
            """
            SELECT symbol, breach_active, last_lag, last_mismatch, safety_mode,
                   last_action_taken, reason, latch_engaged, latch_reason,
                   latch_updated_at, latch_released_at, latch_released_by,
                   updated_at, last_action_at
            FROM reconciliation_safety_state
            WHERE symbol = ?
            """.trimIndent(),
            { rs, _ -> toSafetyState(rs) },
            symbol,
        )
        return rows.firstOrNull()
    }

    fun reconciliationSafetyStates(): Map<String, ReconciliationSafetyState> {
        val rows = jdbc.query(
            """
            SELECT symbol, breach_active, last_lag, last_mismatch, safety_mode,
                   last_action_taken, reason, latch_engaged, latch_reason,
                   latch_updated_at, latch_released_at, latch_released_by,
                   updated_at, last_action_at
            FROM reconciliation_safety_state
            """.trimIndent(),
            { rs, _ -> toSafetyState(rs) },
        )
        return rows.associateBy { it.symbol }
    }

    fun upsertReconciliationSafetyState(
        symbol: String,
        breachActive: Boolean,
        lag: Long,
        mismatch: Boolean,
        safetyMode: String?,
        actionTaken: Boolean,
        reason: String?,
        updatedAt: Instant,
        lastActionAt: Instant?,
        latchEngaged: Boolean,
        latchReason: String?,
        latchUpdatedAt: Instant?,
        latchReleasedAt: Instant?,
        latchReleasedBy: String?,
    ) {
        val updated = jdbc.update(
            """
            UPDATE reconciliation_safety_state
            SET breach_active = ?,
                last_lag = ?,
                last_mismatch = ?,
                safety_mode = ?,
                last_action_taken = ?,
                reason = ?,
                updated_at = ?,
                last_action_at = ?,
                latch_engaged = ?,
                latch_reason = ?,
                latch_updated_at = ?,
                latch_released_at = ?,
                latch_released_by = ?
            WHERE symbol = ?
            """.trimIndent(),
            breachActive,
            lag,
            mismatch,
            safetyMode,
            actionTaken,
            reason,
            java.sql.Timestamp.from(updatedAt),
            lastActionAt?.let { java.sql.Timestamp.from(it) },
            latchEngaged,
            latchReason,
            latchUpdatedAt?.let { java.sql.Timestamp.from(it) },
            latchReleasedAt?.let { java.sql.Timestamp.from(it) },
            latchReleasedBy,
            symbol,
        )
        if (updated > 0) {
            return
        }
        try {
            jdbc.update(
                """
                INSERT INTO reconciliation_safety_state(
                    symbol, breach_active, last_lag, last_mismatch, safety_mode,
                    last_action_taken, reason, updated_at, last_action_at,
                    latch_engaged, latch_reason, latch_updated_at, latch_released_at, latch_released_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                symbol,
                breachActive,
                lag,
                mismatch,
                safetyMode,
                actionTaken,
                reason,
                java.sql.Timestamp.from(updatedAt),
                lastActionAt?.let { java.sql.Timestamp.from(it) },
                latchEngaged,
                latchReason,
                latchUpdatedAt?.let { java.sql.Timestamp.from(it) },
                latchReleasedAt?.let { java.sql.Timestamp.from(it) },
                latchReleasedBy,
            )
        } catch (ex: DataIntegrityViolationException) {
            if (isUniqueViolation(ex)) {
                upsertReconciliationSafetyState(
                    symbol = symbol,
                    breachActive = breachActive,
                    lag = lag,
                    mismatch = mismatch,
                    safetyMode = safetyMode,
                    actionTaken = actionTaken,
                    reason = reason,
                    updatedAt = updatedAt,
                    lastActionAt = lastActionAt,
                    latchEngaged = latchEngaged,
                    latchReason = latchReason,
                    latchUpdatedAt = latchUpdatedAt,
                    latchReleasedAt = latchReleasedAt,
                    latchReleasedBy = latchReleasedBy,
                )
            } else {
                throw ex
            }
        }
    }

    fun releaseReconciliationLatch(
        symbol: String,
        lag: Long,
        mismatch: Boolean,
        safetyMode: String?,
        releaseReason: String,
        releasedBy: String,
        releasedAt: Instant,
    ): Boolean {
        val updated = jdbc.update(
            """
            UPDATE reconciliation_safety_state
            SET breach_active = FALSE,
                last_lag = ?,
                last_mismatch = ?,
                safety_mode = ?,
                last_action_taken = FALSE,
                reason = ?,
                updated_at = ?,
                latch_engaged = FALSE,
                latch_reason = NULL,
                latch_released_at = ?,
                latch_released_by = ?
            WHERE symbol = ? AND latch_engaged = TRUE
            """.trimIndent(),
            lag,
            mismatch,
            safetyMode,
            releaseReason,
            java.sql.Timestamp.from(releasedAt),
            java.sql.Timestamp.from(releasedAt),
            releasedBy,
            symbol,
        )
        return updated > 0
    }

    fun invariantCheck(): InvariantCheckResult {
        val violations = mutableListOf<String>()

        val unbalanced = jdbc.queryForList(
            """
            SELECT entry_id, currency, SUM(CASE WHEN is_debit THEN amount ELSE -amount END) AS signed_sum
            FROM ledger_postings
            GROUP BY entry_id, currency
            HAVING SUM(CASE WHEN is_debit THEN amount ELSE -amount END) <> 0
            """.trimIndent(),
        )
        if (unbalanced.isNotEmpty()) {
            violations += "unbalanced_entries=${unbalanced.size}"
        }

        val negativeBalances = jdbc.queryForList(
            """
            SELECT b.account_id, b.currency, b.balance
            FROM account_balances b
            JOIN accounts a ON a.account_id = b.account_id AND a.currency = b.currency
            WHERE b.balance < 0
              AND a.account_id NOT LIKE 'system:%'
            """.trimIndent(),
        )
        if (negativeBalances.isNotEmpty()) {
            violations += "negative_balances=${negativeBalances.size}"
        }

        if (violations.isNotEmpty()) {
            violations.forEach { v ->
                jdbc.update(
                    "INSERT INTO invariant_alerts(alert_kind, details) VALUES (?, ?)",
                    "INVARIANT_VIOLATION",
                    v,
                )
            }
        }

        return InvariantCheckResult(ok = violations.isEmpty(), violations = violations)
    }

    @Transactional
    fun rebuildBalances() {
        jdbc.update("TRUNCATE TABLE account_balances")
        jdbc.update(
            """
            INSERT INTO account_balances(account_id, currency, balance, updated_at)
            SELECT account_id,
                   currency,
                   SUM(CASE WHEN is_debit THEN amount ELSE -amount END) AS balance,
                   now()
            FROM ledger_postings
            GROUP BY account_id, currency
            """.trimIndent(),
        )
    }

    fun balanceTotalsByKind(): Map<String, Long> {
        val rows = jdbc.queryForList(
            """
            SELECT a.account_kind, COALESCE(SUM(b.balance), 0) AS total
            FROM accounts a
            LEFT JOIN account_balances b
              ON a.account_id = b.account_id AND a.currency = b.currency
            GROUP BY a.account_kind
            """.trimIndent(),
        )
        return rows.associate { row ->
            row["account_kind"].toString() to (row["total"] as Number).toLong()
        }
    }

    fun createCorrectionRequest(
        correctionId: String,
        originalEntryId: String,
        mode: String,
        reason: String,
        ticketId: String,
        requestedBy: String,
    ) {
        jdbc.update(
            """
            INSERT INTO correction_requests(
                correction_id, original_entry_id, mode, reason,
                ticket_id, requested_by, status
            ) VALUES (?, ?, ?, ?, ?, ?, 'PENDING')
            """.trimIndent(),
            correctionId,
            originalEntryId,
            mode,
            reason,
            ticketId,
            requestedBy,
        )
    }

    @Transactional
    fun approveCorrection(correctionId: String, approver: String): CorrectionRequest {
        val current = getCorrection(correctionId)
        if (current.status == "APPLIED") {
            return current
        }

        var nextApprover1 = current.approver1
        var nextApprover2 = current.approver2
        if (nextApprover1 == null) {
            nextApprover1 = approver
        } else if (nextApprover1 != approver && nextApprover2 == null) {
            nextApprover2 = approver
        }
        val status = if (nextApprover2 != null && nextApprover1 != nextApprover2) {
            "APPROVED"
        } else {
            "PENDING"
        }

        jdbc.update(
            """
            UPDATE correction_requests
            SET approver1 = ?, approver2 = ?, status = ?, approved_at = CASE WHEN ? = 'APPROVED' THEN now() ELSE approved_at END
            WHERE correction_id = ?
            """.trimIndent(),
            nextApprover1,
            nextApprover2,
            status,
            status,
            correctionId,
        )

        return getCorrection(correctionId)
    }

    fun markCorrectionApplied(correctionId: String) {
        jdbc.update(
            "UPDATE correction_requests SET status = 'APPLIED', approved_at = COALESCE(approved_at, now()) WHERE correction_id = ?",
            correctionId,
        )
    }

    fun getCorrection(correctionId: String): CorrectionRequest {
        return jdbc.queryForObject(
            """
            SELECT correction_id, original_entry_id, mode, reason, ticket_id, requested_by, approver1, approver2, status
            FROM correction_requests
            WHERE correction_id = ?
            """.trimIndent(),
            { rs, _ ->
                CorrectionRequest(
                    correctionId = rs.getString("correction_id"),
                    originalEntryId = rs.getString("original_entry_id"),
                    mode = rs.getString("mode"),
                    reason = rs.getString("reason"),
                    ticketId = rs.getString("ticket_id"),
                    requestedBy = rs.getString("requested_by"),
                    approver1 = rs.getString("approver1"),
                    approver2 = rs.getString("approver2"),
                    status = rs.getString("status"),
                )
            },
            correctionId,
        )!!
    }

    fun oldestPendingCorrectionCreatedAt(): Instant? {
        val rows = jdbc.queryForList(
            "SELECT MIN(created_at) AS min_created_at FROM correction_requests WHERE status = 'PENDING'",
        )
        if (rows.isEmpty()) {
            return null
        }
        return (rows.first()["min_created_at"] as? java.sql.Timestamp)?.toInstant()
    }

    fun reverseEntry(originalEntryId: String, correctionEntryId: String, correlationId: String, causationId: String): Boolean {
        val header = jdbc.queryForList(
            "SELECT reference_id, symbol, engine_seq FROM ledger_entries WHERE entry_id = ?",
            originalEntryId,
        ).firstOrNull() ?: return false

        val postings = jdbc.queryForList(
            "SELECT account_id, currency, amount, is_debit FROM ledger_postings WHERE entry_id = ?",
            originalEntryId,
        )

        val command = LedgerEntryCommand(
            entryId = correctionEntryId,
            referenceType = "CORRECTION",
            referenceId = originalEntryId,
            entryKind = "REVERSAL",
            symbol = header["symbol"].toString(),
            engineSeq = (header["engine_seq"] as Number).toLong(),
            occurredAt = Instant.now(),
            correlationId = correlationId,
            causationId = causationId,
            postings = postings.map { row ->
                LedgerPostingCommand(
                    accountId = row["account_id"].toString(),
                    currency = row["currency"].toString(),
                    amount = (row["amount"] as Number).toLong(),
                    isDebit = !(row["is_debit"] as Boolean),
                )
            },
        )
        return appendEntry(command)
    }

    fun listBalances(): Map<String, Long> {
        val rows = jdbc.queryForList("SELECT account_id, currency, balance FROM account_balances")
        return rows.associate { row ->
            "${row["account_id"]}:${row["currency"]}" to (row["balance"] as Number).toLong()
        }
    }

    fun findTrade(tradeId: String): TradeLookup? {
        val rows = jdbc.queryForList(
            """
            SELECT entry_id, symbol, engine_seq, occurred_at
            FROM ledger_entries
            WHERE reference_type = 'TRADE' AND reference_id = ?
            ORDER BY occurred_at DESC
            LIMIT 1
            """.trimIndent(),
            tradeId,
        )
        val row = rows.firstOrNull() ?: return null
        return TradeLookup(
            tradeId = tradeId,
            entryId = row["entry_id"].toString(),
            symbol = row["symbol"].toString(),
            engineSeq = (row["engine_seq"] as Number).toLong(),
            occurredAt = (row["occurred_at"] as java.sql.Timestamp).toInstant(),
        )
    }

    private fun toReconciliationStatus(symbol: String, lastEngineSeq: Long, lastSettledSeq: Long, updatedAt: java.sql.Timestamp?): ReconciliationStatus {
        return ReconciliationStatus(
            symbol = symbol,
            lastEngineSeq = lastEngineSeq,
            lastSettledSeq = lastSettledSeq,
            gap = lastEngineSeq - lastSettledSeq,
            updatedAt = updatedAt?.toInstant(),
        )
    }

    private fun toSafetyState(rs: ResultSet): ReconciliationSafetyState {
        return ReconciliationSafetyState(
            symbol = rs.getString("symbol"),
            breachActive = rs.getBoolean("breach_active"),
            lastLag = rs.getLong("last_lag"),
            lastMismatch = rs.getBoolean("last_mismatch"),
            safetyMode = rs.getString("safety_mode"),
            lastActionTaken = rs.getBoolean("last_action_taken"),
            reason = rs.getString("reason"),
            latchEngaged = rs.getBoolean("latch_engaged"),
            latchReason = rs.getString("latch_reason"),
            latchUpdatedAt = rs.getTimestamp("latch_updated_at")?.toInstant(),
            latchReleasedAt = rs.getTimestamp("latch_released_at")?.toInstant(),
            latchReleasedBy = rs.getString("latch_released_by"),
            updatedAt = rs.getTimestamp("updated_at").toInstant(),
            lastActionAt = rs.getTimestamp("last_action_at")?.toInstant(),
        )
    }

    private fun isDoubleEntry(command: LedgerEntryCommand): Boolean {
        val sums = mutableMapOf<String, Long>()
        command.postings.forEach { p ->
            val signed = if (p.isDebit) p.amount else -p.amount
            sums[p.currency] = (sums[p.currency] ?: 0L) + signed
        }
        return sums.values.all { it == 0L }
    }

    private fun ensureAccount(accountId: String, currency: String) {
        val kind = accountId.substringAfterLast(':', "AVAILABLE").uppercase()
        val userId = if (accountId.startsWith("user:")) {
            accountId.substringAfter("user:").substringBefore(':')
        } else {
            "system"
        }
        val exists = jdbc.queryForObject(
            "SELECT COUNT(*) FROM accounts WHERE account_id = ?",
            Long::class.java,
            accountId,
        ) ?: 0L
        if (exists > 0) {
            return
        }
        jdbc.update(
            """
            INSERT INTO accounts(account_id, user_id, currency, account_kind)
            VALUES (?, ?, ?, ?)
            """.trimIndent(),
            accountId,
            userId,
            currency,
            kind,
        )
    }

    private fun isUniqueViolation(ex: DataIntegrityViolationException): Boolean {
        val msg = ex.rootCause?.message?.lowercase() ?: ex.message?.lowercase().orEmpty()
        return msg.contains("unique") || msg.contains("duplicate")
    }

    private fun applyBalanceDelta(accountId: String, currency: String, delta: Long) {
        val updated = jdbc.update(
            """
            UPDATE account_balances
            SET balance = balance + ?, updated_at = now()
            WHERE account_id = ? AND currency = ?
            """.trimIndent(),
            delta,
            accountId,
            currency,
        )
        if (updated > 0) {
            return
        }
        try {
            jdbc.update(
                """
                INSERT INTO account_balances(account_id, currency, balance, updated_at)
                VALUES (?, ?, ?, now())
                """.trimIndent(),
                accountId,
                currency,
                delta,
            )
        } catch (ex: DataIntegrityViolationException) {
            if (isUniqueViolation(ex)) {
                jdbc.update(
                    """
                    UPDATE account_balances
                    SET balance = balance + ?, updated_at = now()
                    WHERE account_id = ? AND currency = ?
                    """.trimIndent(),
                    delta,
                    accountId,
                    currency,
                )
            } else {
                throw ex
            }
        }
    }
}
