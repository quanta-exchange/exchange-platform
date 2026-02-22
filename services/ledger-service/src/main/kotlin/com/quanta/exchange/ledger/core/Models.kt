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

data class TradeLookup(
    val tradeId: String,
    val entryId: String,
    val symbol: String,
    val engineSeq: Long,
    val occurredAt: Instant,
)

enum class SafetyMode {
    NORMAL,
    CANCEL_ONLY,
    SOFT_HALT,
    HARD_HALT,
    ;

    companion object {
        fun parse(value: String): SafetyMode {
            return when (value.trim().uppercase()) {
                "NORMAL" -> NORMAL
                "CANCEL_ONLY" -> CANCEL_ONLY
                "SOFT_HALT" -> SOFT_HALT
                "HARD_HALT", "HALT" -> HARD_HALT
                else -> CANCEL_ONLY
            }
        }
    }
}

data class ReconciliationEvaluation(
    val symbol: String,
    val lastEngineSeq: Long,
    val lastSettledSeq: Long,
    val lag: Long,
    val mismatch: Boolean,
    val threshold: Long,
    val breached: Boolean,
    val reason: String,
    val safetyMode: SafetyMode,
    val safetyActionTaken: Boolean,
    val checkedAt: Instant,
)

data class ReconciliationHistoryPoint(
    val id: Long,
    val symbol: String,
    val lastEngineSeq: Long,
    val lastSettledSeq: Long,
    val lag: Long,
    val mismatch: Boolean,
    val threshold: Long,
    val breached: Boolean,
    val safetyMode: String?,
    val safetyActionTaken: Boolean,
    val reason: String,
    val checkedAt: Instant,
)

data class ReconciliationSafetyState(
    val symbol: String,
    val breachActive: Boolean,
    val lastLag: Long,
    val lastMismatch: Boolean,
    val safetyMode: String?,
    val lastActionTaken: Boolean,
    val reason: String?,
    val latchEngaged: Boolean,
    val latchReason: String?,
    val latchUpdatedAt: Instant?,
    val latchReleasedAt: Instant?,
    val latchReleasedBy: String?,
    val updatedAt: Instant,
    val lastActionAt: Instant?,
)

data class ReconciliationStatusView(
    val symbol: String,
    val lastEngineSeq: Long,
    val lastSettledSeq: Long,
    val lag: Long,
    val mismatch: Boolean,
    val thresholdBreached: Boolean,
    val breached: Boolean,
    val breachActive: Boolean,
    val safetyMode: String?,
    val lastActionAt: Instant?,
    val latchEngaged: Boolean,
    val latchReason: String?,
    val latchUpdatedAt: Instant?,
    val latchReleasedAt: Instant?,
    val latchReleasedBy: String?,
    val updatedAt: Instant?,
)

data class ReconciliationRunSummary(
    val checkedAt: Instant,
    val evaluations: List<ReconciliationEvaluation>,
)

data class ReconciliationDashboard(
    val checkedAt: Instant,
    val statuses: List<ReconciliationStatusView>,
    val history: List<ReconciliationHistoryPoint>,
)

data class ReconciliationLatchReleaseResult(
    val symbol: String,
    val released: Boolean,
    val modeRestored: Boolean,
    val reason: String,
    val lag: Long,
    val mismatch: Boolean,
    val thresholdBreached: Boolean,
    val invariantsOk: Boolean,
    val invariantViolations: List<String>,
    val releasedAt: Instant?,
    val releasedBy: String?,
)

data class SafetyModeActivationSummary(
    val requestedSymbols: List<String>,
    val switchedSymbols: List<String>,
    val failedSymbols: List<String>,
)
