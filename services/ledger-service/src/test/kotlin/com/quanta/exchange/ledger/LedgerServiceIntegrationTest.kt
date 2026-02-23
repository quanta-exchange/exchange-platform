package com.quanta.exchange.ledger

import com.quanta.exchange.ledger.core.BalanceAdjustmentCommand
import com.quanta.exchange.ledger.core.EventEnvelope
import com.quanta.exchange.ledger.core.LedgerMetrics
import com.quanta.exchange.ledger.core.LedgerService
import com.quanta.exchange.ledger.core.ReserveCommand
import com.quanta.exchange.ledger.core.SafetyMode
import com.quanta.exchange.ledger.core.TradeExecuted
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.ActiveProfiles
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

@SpringBootTest
@ActiveProfiles("test")
class LedgerServiceIntegrationTest {
    @Autowired
    lateinit var ledgerService: LedgerService

    @Autowired
    lateinit var jdbc: JdbcTemplate

    @Autowired
    lateinit var ledgerMetrics: LedgerMetrics

    @BeforeEach
    fun cleanDb() {
        listOf(
            "DELETE FROM reconciliation_history",
            "DELETE FROM reconciliation_safety_state",
            "DELETE FROM correction_requests",
            "DELETE FROM invariant_alerts",
            "DELETE FROM settlement_dlq",
            "DELETE FROM account_balances",
            "DELETE FROM settlement_idempotency",
            "DELETE FROM ledger_postings",
            "DELETE FROM ledger_entries",
            "DELETE FROM accounts",
            "DELETE FROM reconciliation_state",
        ).forEach { jdbc.update(it) }
    }

    @Test
    fun settlementIsIdempotentAndDlqOnFailure() {
        seedBalancesAndReserves()
        val trade = trade(tradeId = "trade-1", seq = 10)

        val applied = ledgerService.consumeTrade(trade)
        val duplicate = ledgerService.consumeTrade(trade)
        assertTrue(applied.applied)
        assertFalse(duplicate.applied)
        assertEquals("duplicate", duplicate.reason)

        val count = jdbc.queryForObject(
            "SELECT COUNT(*) FROM ledger_entries WHERE reference_type='TRADE' AND reference_id='trade-1' AND entry_kind='FILL'",
            Long::class.java,
        )!!
        assertEquals(1L, count)

        val badSymbolTrade = trade.copy(
            tradeId = "trade-2",
            envelope = trade.envelope.copy(symbol = "INVALID"),
        )
        val failed = ledgerService.consumeTrade(badSymbolTrade)
        assertFalse(failed.applied)
        assertEquals("dlq", failed.reason)
        val dlqCount = jdbc.queryForObject("SELECT COUNT(*) FROM settlement_dlq", Long::class.java)!!
        assertEquals(1L, dlqCount)
    }

    @Test
    fun reserveFillReleaseWorkflowKeepsHoldConsistent() {
        ledgerService.adjustAvailable(adjustment("seed-buyer", "buyer", "KRW", 200_000))
        ledgerService.adjustAvailable(adjustment("seed-seller", "seller", "BTC", 2))

        assertTrue(ledgerService.reserve(reserve("ord-buy-2", "buyer", "BUY", 200_000, 2)))
        assertTrue(ledgerService.reserve(reserve("ord-sell-2", "seller", "SELL", 1, 3)))
        assertTrue(ledgerService.consumeTrade(trade("trade-2", 4)).applied)
        assertTrue(ledgerService.release(reserve("ord-buy-2", "buyer", "BUY", 100_000, 5)))

        val balances = ledgerService.listBalances()
        assertEquals(0L, balances["user:buyer:KRW:HOLD:KRW"])
        assertEquals(100_000L, balances["user:buyer:KRW:AVAILABLE:KRW"])
        assertEquals(1L, balances["user:buyer:BTC:AVAILABLE:BTC"])
        assertEquals(0L, balances["user:seller:BTC:HOLD:BTC"])
        assertEquals(100_000L, balances["user:seller:KRW:AVAILABLE:KRW"])
    }

    @Test
    fun rebuildRestoresBalancesAfterCorruption() {
        ledgerService.adjustAvailable(adjustment("seed-u1", "u1", "USDT", 500))
        ledgerService.adjustAvailable(adjustment("seed-u2", "u2", "USDT", 200))
        val before = ledgerService.listBalances()

        jdbc.update(
            "UPDATE account_balances SET balance = balance + 999 WHERE account_id = ? AND currency = ?",
            "user:u1:USDT:AVAILABLE",
            "USDT",
        )
        ledgerService.rebuildBalances()
        val after = ledgerService.listBalances()
        assertEquals(before, after)
    }

    @Test
    fun invariantGuardDetectsForcedViolation() {
        jdbc.update(
            "INSERT INTO accounts(account_id, user_id, currency, account_kind) VALUES (?, ?, ?, ?)",
            "user:violator:KRW:AVAILABLE",
            "violator",
            "KRW",
            "AVAILABLE",
        )
        jdbc.update(
            """
            INSERT INTO ledger_entries(entry_id, reference_type, reference_id, entry_kind, symbol, engine_seq, occurred_at, correlation_id, causation_id)
            VALUES ('bad-entry', 'TEST', 'bad-ref', 'MANUAL', 'BTC-KRW', 1, CURRENT_TIMESTAMP, 'corr-1', 'cause-1')
            """.trimIndent(),
        )
        jdbc.update(
            """
            INSERT INTO ledger_postings(posting_id, entry_id, account_id, currency, amount, is_debit)
            VALUES ('bad-posting', 'bad-entry', 'user:violator:KRW:AVAILABLE', 'KRW', 100, TRUE)
            """.trimIndent(),
        )
        jdbc.update(
            "INSERT INTO account_balances(account_id, currency, balance) VALUES ('user:violator:KRW:AVAILABLE', 'KRW', -100)",
        )

        val result = ledgerService.runInvariantCheck()
        assertFalse(result.ok)
        assertTrue(result.violations.isNotEmpty())
        val alerts = jdbc.queryForObject("SELECT COUNT(*) FROM invariant_alerts", Long::class.java)!!
        assertTrue(alerts >= 1)
    }

    @Test
    fun reconciliationGapTracksEngineVsSettledSeq() {
        ledgerService.updateEngineSeq("BTC-KRW", 50)
        seedBalancesAndReserves()
        assertTrue(ledgerService.consumeTrade(trade("trade-gap", 40)).applied)

        val status = ledgerService.reconciliation("BTC-KRW")
        assertEquals(50L, status.lastEngineSeq)
        assertEquals(40L, status.lastSettledSeq)
        assertEquals(10L, status.gap)
    }

    @Test
    fun reconciliationEvaluationRecordsHistoryAndSafetyState() {
        ledgerService.updateEngineSeq("BTC-KRW", 50)
        seedBalancesAndReserves()
        assertTrue(ledgerService.consumeTrade(trade("trade-recon-eval", 40)).applied)

        val run = ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = false,
            safetyLatchEnabled = true,
        )

        assertEquals(1, run.evaluations.size)
        val evaluation = run.evaluations.first()
        assertTrue(evaluation.breached)
        assertFalse(evaluation.safetyActionTaken)
        assertEquals(10L, evaluation.lag)

        val historyCount = jdbc.queryForObject("SELECT COUNT(*) FROM reconciliation_history WHERE symbol = 'BTC-KRW'", Long::class.java)!!
        assertEquals(1L, historyCount)
        val active = jdbc.queryForObject(
            "SELECT breach_active FROM reconciliation_safety_state WHERE symbol = 'BTC-KRW'",
            Boolean::class.java,
        )!!
        assertTrue(active)
    }

    @Test
    fun reconciliationEvaluationBreachesWhenStateIsStale() {
        ledgerService.updateEngineSeq("BTC-KRW", 10)
        jdbc.update(
            "UPDATE reconciliation_state SET last_settled_seq = ?, updated_at = ? WHERE symbol = ?",
            10L,
            java.sql.Timestamp.from(Instant.now().minusSeconds(120)),
            "BTC-KRW",
        )

        val run = ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = false,
            safetyLatchEnabled = true,
            staleStateThresholdMs = 1_000,
        )
        val evaluation = run.evaluations.first()
        assertTrue(evaluation.breached)
        assertEquals("state_stale", evaluation.reason)

        val status = ledgerService.reconciliationStatus(
            historyLimit = 5,
            lagThreshold = 5,
            staleStateThresholdMs = 1_000,
        ).statuses.first { it.symbol == "BTC-KRW" }
        assertTrue(status.staleThresholdBreached)
        assertTrue(status.breached)
        assertTrue(status.stateAgeMs >= 1_000)
    }

    @Test
    fun reconciliationRetriesSafetySwitchWhenPreviousAttemptFailed() {
        ledgerService.updateEngineSeq("BTC-KRW", 50)
        seedBalancesAndReserves()
        assertTrue(ledgerService.consumeTrade(trade("trade-recon-retry", 40)).applied)

        val alertsBefore = metricValue("reconciliation_alert_total")
        val failuresBefore = metricValue("reconciliation_safety_failure_total")
        ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = true,
            safetyLatchEnabled = true,
        )
        ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = true,
            safetyLatchEnabled = true,
        )

        assertEquals(alertsBefore + 2, metricValue("reconciliation_alert_total"))
        assertEquals(failuresBefore + 2, metricValue("reconciliation_safety_failure_total"))
    }

    @Test
    fun safetyLatchRemainsActiveUntilManualRelease() {
        ledgerService.updateEngineSeq("BTC-KRW", 50)
        seedBalancesAndReserves()
        assertTrue(ledgerService.consumeTrade(trade("trade-latch-1", 40)).applied)

        val breachRun = ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = false,
            safetyLatchEnabled = true,
        )
        assertTrue(breachRun.evaluations.first().breached)

        assertTrue(ledgerService.reserve(reserve("ord-buy-latch-2", "buyer", "BUY", 100_000, 45)))
        assertTrue(ledgerService.reserve(reserve("ord-sell-latch-2", "seller", "SELL", 1, 46)))
        assertTrue(ledgerService.consumeTrade(trade("trade-latch-1b", 50)).applied)
        val recoveredRun = ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = false,
            safetyLatchEnabled = true,
        )
        assertFalse(recoveredRun.evaluations.first().breached)

        val statusBeforeRelease = ledgerService.reconciliationStatus(historyLimit = 5, lagThreshold = 5)
            .statuses
            .first { it.symbol == "BTC-KRW" }
        assertTrue(statusBeforeRelease.latchEngaged)
        assertTrue(statusBeforeRelease.breachActive)

        val release = ledgerService.releaseReconciliationLatch(
            symbol = "BTC-KRW",
            lagThreshold = 5,
            approvedBy = "ops-1",
            reason = "reconciliation_verified",
            restoreSymbolMode = false,
            allowNegativeBalanceViolations = false,
        )
        assertTrue(release.released) { "release=$release" }
        assertTrue(release.invariantsOk) { "release=$release" }

        val statusAfterRelease = ledgerService.reconciliationStatus(historyLimit = 5, lagThreshold = 5)
            .statuses
            .first { it.symbol == "BTC-KRW" }
        assertFalse(statusAfterRelease.latchEngaged)
        assertFalse(statusAfterRelease.breachActive)
    }

    @Test
    fun latchReleaseIsRejectedWhileStillBreached() {
        ledgerService.updateEngineSeq("BTC-KRW", 50)
        seedBalancesAndReserves()
        assertTrue(ledgerService.consumeTrade(trade("trade-latch-2", 40)).applied)
        ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = false,
            safetyLatchEnabled = true,
        )

        val release = ledgerService.releaseReconciliationLatch(
            symbol = "BTC-KRW",
            lagThreshold = 5,
            approvedBy = "ops-2",
            reason = "attempt_before_recovery",
            restoreSymbolMode = false,
            allowNegativeBalanceViolations = false,
        )
        assertFalse(release.released)
        assertEquals("still_breached", release.reason)
    }

    @Test
    fun latchReleaseIsRejectedWhenInvariantsFail() {
        ledgerService.updateEngineSeq("BTC-KRW", 50)
        seedBalancesAndReserves()
        assertTrue(ledgerService.consumeTrade(trade("trade-latch-3", 40)).applied)
        ledgerService.runReconciliationEvaluation(
            lagThreshold = 5,
            safetyMode = SafetyMode.CANCEL_ONLY,
            autoSwitchEnabled = false,
            safetyLatchEnabled = true,
        )
        assertTrue(ledgerService.reserve(reserve("ord-buy-latch-3", "buyer", "BUY", 100_000, 45)))
        assertTrue(ledgerService.reserve(reserve("ord-sell-latch-3", "seller", "SELL", 1, 46)))
        assertTrue(ledgerService.consumeTrade(trade("trade-latch-3b", 50)).applied)

        jdbc.update(
            "INSERT INTO accounts(account_id, user_id, currency, account_kind) VALUES (?, ?, ?, ?)",
            "user:bad:KRW:AVAILABLE",
            "bad",
            "KRW",
            "AVAILABLE",
        )
        jdbc.update(
            "INSERT INTO account_balances(account_id, currency, balance) VALUES (?, ?, ?)",
            "user:bad:KRW:AVAILABLE",
            "KRW",
            -1,
        )

        val release = ledgerService.releaseReconciliationLatch(
            symbol = "BTC-KRW",
            lagThreshold = 5,
            approvedBy = "ops-3",
            reason = "attempt_with_bad_invariants",
            restoreSymbolMode = false,
            allowNegativeBalanceViolations = false,
        )
        assertFalse(release.released)
        assertEquals("invariants_failed", release.reason)
        assertFalse(release.invariantsOk)
        assertTrue(release.invariantViolations.isNotEmpty())
    }

    @Test
    fun invariantSafetyActivationTargetsTrackedSymbols() {
        ledgerService.updateEngineSeq("BTC-KRW", 10)
        val summary = ledgerService.activateSafetyModeForTrackedSymbols(
            mode = SafetyMode.CANCEL_ONLY,
            reason = "test_invariant_violation",
        )
        assertTrue(summary.requestedSymbols.contains("BTC-KRW"))
        assertTrue(summary.switchedSymbols.isEmpty())
        assertTrue(summary.failedSymbols.contains("BTC-KRW"))
    }

    @Test
    fun correctionsRequireTwoApproversAndReverseHistory() {
        assertTrue(ledgerService.adjustAvailable(adjustment("corr-base", "alice", "USD", 500)))

        ledgerService.createCorrection(
            correctionId = "corr-1",
            originalEntryId = "le_adj_corr-base",
            mode = "REVERSAL",
            reason = "operator mistake",
            ticketId = "TKT-1",
            requestedBy = "ops-a",
        )

        val pending = ledgerService.approveCorrection("corr-1", "ops-b")
        assertEquals("PENDING", pending.status)

        val approved = ledgerService.approveCorrection("corr-1", "ops-c")
        assertEquals("APPROVED", approved.status)

        val result = ledgerService.applyCorrection(
            correctionId = "corr-1",
            envelope = envelope(symbol = "USD-USD", seq = 900),
        )
        assertTrue(result.applied)
        val balances = ledgerService.listBalances()
        assertEquals(0L, balances["user:alice:USD:AVAILABLE:USD"])
    }

    @Test
    fun correctionCreationRejectsUnknownOriginalEntry() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            ledgerService.createCorrection(
                correctionId = "corr-missing-entry",
                originalEntryId = "le_missing_entry",
                mode = "REVERSAL",
                reason = "bad request",
                ticketId = "TKT-404",
                requestedBy = "ops-a",
            )
        }
        assertEquals("original_entry_not_found", error.message)
    }

    @Test
    fun correctionCreationRejectsUnsupportedMode() {
        assertTrue(ledgerService.adjustAvailable(adjustment("corr-mode-base", "alice", "USD", 500)))
        val error = assertThrows(IllegalArgumentException::class.java) {
            ledgerService.createCorrection(
                correctionId = "corr-bad-mode",
                originalEntryId = "le_adj_corr-mode-base",
                mode = "ADJUSTMENT",
                reason = "unsupported mode",
                ticketId = "TKT-405",
                requestedBy = "ops-a",
            )
        }
        assertEquals("unsupported_correction_mode", error.message)
    }

    @Test
    fun concurrentApprovalsRemainConsistent() {
        assertTrue(ledgerService.adjustAvailable(adjustment("corr-race-base", "alice", "USD", 500)))
        ledgerService.createCorrection(
            correctionId = "corr-race-1",
            originalEntryId = "le_adj_corr-race-base",
            mode = "REVERSAL",
            reason = "race check",
            ticketId = "TKT-RACE",
            requestedBy = "ops-a",
        )

        val pool = Executors.newFixedThreadPool(2)
        val start = java.util.concurrent.CountDownLatch(1)
        val errorRef = AtomicReference<Throwable?>()

        try {
            val futures = listOf("ops-b", "ops-c").map { approver ->
                pool.submit {
                    start.await(2, TimeUnit.SECONDS)
                    try {
                        ledgerService.approveCorrection("corr-race-1", approver)
                    } catch (ex: Throwable) {
                        errorRef.compareAndSet(null, ex)
                    }
                }
            }
            start.countDown()
            futures.forEach { it.get(5, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }

        val error = errorRef.get()
        if (error != null) {
            throw AssertionError("concurrent approval failed", error)
        }

        val row = jdbc.queryForMap(
            "SELECT status, approver1, approver2 FROM correction_requests WHERE correction_id = ?",
            "corr-race-1",
        )
        val status = row["status"]?.toString()
        val approver1 = row["approver1"]?.toString()
        val approver2 = row["approver2"]?.toString()
        assertEquals("APPROVED", status)
        assertTrue(!approver1.isNullOrBlank())
        assertTrue(!approver2.isNullOrBlank())
        assertEquals(setOf("ops-b", "ops-c"), setOf(approver1!!, approver2!!))
    }

    @Test
    fun concurrentCorrectionApplyRemainsAtomic() {
        assertTrue(ledgerService.adjustAvailable(adjustment("corr-apply-base", "alice", "USD", 500)))
        ledgerService.createCorrection(
            correctionId = "corr-apply-race",
            originalEntryId = "le_adj_corr-apply-base",
            mode = "REVERSAL",
            reason = "apply race check",
            ticketId = "TKT-APPLY-RACE",
            requestedBy = "ops-a",
        )
        ledgerService.approveCorrection("corr-apply-race", "ops-b")
        ledgerService.approveCorrection("corr-apply-race", "ops-c")

        val pool = Executors.newFixedThreadPool(2)
        val start = java.util.concurrent.CountDownLatch(1)
        val results = CopyOnWriteArrayList<Boolean>()
        val errorRef = AtomicReference<Throwable?>()

        try {
            val futures = listOf(1L, 2L).map { seq ->
                pool.submit {
                    start.await(2, TimeUnit.SECONDS)
                    try {
                        val result = ledgerService.applyCorrection(
                            correctionId = "corr-apply-race",
                            envelope = envelope(symbol = "USD-USD", seq = 10_000 + seq),
                        )
                        results += result.applied
                    } catch (ex: Throwable) {
                        errorRef.compareAndSet(null, ex)
                    }
                }
            }
            start.countDown()
            futures.forEach { it.get(5, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }

        val error = errorRef.get()
        if (error != null) {
            throw AssertionError("concurrent apply failed", error)
        }

        val appliedCount = results.count { it }
        assertEquals(1, appliedCount)

        val correctionRows = jdbc.queryForObject(
            "SELECT COUNT(*) FROM ledger_entries WHERE entry_id = ? AND reference_type = 'CORRECTION'",
            Long::class.java,
            "le_corr_corr-apply-race",
        )!!
        assertEquals(1L, correctionRows)

        val status = jdbc.queryForObject(
            "SELECT status FROM correction_requests WHERE correction_id = ?",
            String::class.java,
            "corr-apply-race",
        )!!
        assertEquals("APPLIED", status)
    }

    private fun seedBalancesAndReserves() {
        ledgerService.adjustAvailable(adjustment("seed-buyer-trade", "buyer", "KRW", 200_000))
        ledgerService.adjustAvailable(adjustment("seed-seller-trade", "seller", "BTC", 2))
        ledgerService.reserve(reserve("ord-buy-1", "buyer", "BUY", 100_000, 2))
        ledgerService.reserve(reserve("ord-sell-1", "seller", "SELL", 1, 3))
    }

    private fun reserve(orderId: String, userId: String, side: String, amount: Long, seq: Long): ReserveCommand {
        return ReserveCommand(
            envelope = envelope(seq = seq),
            orderId = orderId,
            userId = userId,
            side = side,
            amount = amount,
        )
    }

    private fun trade(tradeId: String, seq: Long): TradeExecuted {
        return TradeExecuted(
            envelope = envelope(seq = seq),
            tradeId = tradeId,
            buyerUserId = "buyer",
            sellerUserId = "seller",
            price = 100_000,
            quantity = 1,
            quoteAmount = 100_000,
            feeBuyer = 0,
            feeSeller = 0,
        )
    }

    private fun adjustment(referenceId: String, userId: String, currency: String, delta: Long): BalanceAdjustmentCommand {
        return BalanceAdjustmentCommand(
            envelope = envelope(symbol = "$currency-$currency"),
            referenceId = referenceId,
            userId = userId,
            currency = currency,
            amountDelta = delta,
        )
    }

    private fun envelope(symbol: String = "BTC-KRW", seq: Long = 1): EventEnvelope {
        return EventEnvelope(
            eventId = "evt-$seq-${Instant.now().toEpochMilli()}",
            eventVersion = 1,
            symbol = symbol,
            seq = seq,
            occurredAt = Instant.now().minusMillis(100),
            correlationId = "corr-$seq",
            causationId = "cause-$seq",
        )
    }

    private fun metricValue(name: String): Long {
        val line = ledgerMetrics.renderPrometheus()
            .lineSequence()
            .firstOrNull { it.startsWith("$name ") }
            ?: return 0
        return line.substringAfter(' ').trim().toLong()
    }
}
