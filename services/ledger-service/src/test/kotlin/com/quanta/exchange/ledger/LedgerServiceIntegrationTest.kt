package com.quanta.exchange.ledger

import com.quanta.exchange.ledger.core.BalanceAdjustmentCommand
import com.quanta.exchange.ledger.core.EventEnvelope
import com.quanta.exchange.ledger.core.LedgerService
import com.quanta.exchange.ledger.core.ReserveCommand
import com.quanta.exchange.ledger.core.TradeExecuted
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeEach
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.jdbc.core.JdbcTemplate
import org.springframework.test.context.ActiveProfiles
import java.time.Instant

@SpringBootTest
@ActiveProfiles("test")
class LedgerServiceIntegrationTest {
    @Autowired
    lateinit var ledgerService: LedgerService

    @Autowired
    lateinit var jdbc: JdbcTemplate

    @BeforeEach
    fun cleanDb() {
        listOf(
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
}
