package com.quanta.exchange.ledger.repo

import com.quanta.exchange.ledger.core.CorrectionRequest
import com.quanta.exchange.ledger.core.InvariantCheckResult
import com.quanta.exchange.ledger.core.LedgerEntryCommand
import com.quanta.exchange.ledger.core.LedgerPostingCommand
import com.quanta.exchange.ledger.core.ReconciliationStatus
import org.springframework.dao.DataIntegrityViolationException
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.stereotype.Repository
import org.springframework.transaction.annotation.Transactional
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

        updateSettledSeq(command.symbol, command.engineSeq)
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
            "SELECT account_id, currency, balance FROM account_balances WHERE balance < 0",
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
