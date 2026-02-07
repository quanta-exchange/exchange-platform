package com.quanta.exchange.ledger.core

import java.time.Instant

data class EventEnvelope(
    val eventId: String,
    val eventVersion: Int,
    val symbol: String,
    val seq: Long,
    val occurredAt: Instant,
    val correlationId: String,
    val causationId: String,
)

data class LedgerPostingCommand(
    val accountId: String,
    val currency: String,
    val amount: Long,
    val isDebit: Boolean,
)

data class LedgerEntryCommand(
    val entryId: String,
    val referenceType: String,
    val referenceId: String,
    val entryKind: String,
    val symbol: String,
    val engineSeq: Long,
    val occurredAt: Instant,
    val correlationId: String,
    val causationId: String,
    val postings: List<LedgerPostingCommand>,
)

data class TradeExecuted(
    val envelope: EventEnvelope,
    val tradeId: String,
    val buyerUserId: String,
    val sellerUserId: String,
    val price: Long,
    val quantity: Long,
    val quoteAmount: Long,
    val feeBuyer: Long = 0,
    val feeSeller: Long = 0,
)

data class ReserveCommand(
    val envelope: EventEnvelope,
    val orderId: String,
    val userId: String,
    val side: String,
    val amount: Long,
)

data class BalanceAdjustmentCommand(
    val envelope: EventEnvelope,
    val referenceId: String,
    val userId: String,
    val currency: String,
    val amountDelta: Long,
)

data class SettlementResult(
    val applied: Boolean,
    val entryId: String,
    val reason: String,
)

data class InvariantCheckResult(
    val ok: Boolean,
    val violations: List<String>,
)

data class ReconciliationStatus(
    val symbol: String,
    val lastEngineSeq: Long,
    val lastSettledSeq: Long,
    val gap: Long,
    val updatedAt: Instant?,
)

data class CorrectionRequest(
    val correctionId: String,
    val originalEntryId: String,
    val mode: String,
    val reason: String,
    val ticketId: String,
    val requestedBy: String,
    val approver1: String?,
    val approver2: String?,
    val status: String,
)
