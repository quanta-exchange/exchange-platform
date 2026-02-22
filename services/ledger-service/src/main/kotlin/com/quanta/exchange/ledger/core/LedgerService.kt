package com.quanta.exchange.ledger.core

import com.quanta.exchange.ledger.repo.LedgerRepository
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service
import java.time.Duration
import java.time.Instant

@Service
class LedgerService(
    private val repo: LedgerRepository,
    private val metrics: LedgerMetrics,
    private val symbolModeSwitcher: SymbolModeSwitcher,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    fun consumeTrade(event: TradeExecuted): SettlementResult {
        val started = System.nanoTime()
        val entryId = "le_trade_${event.tradeId}"
        return try {
            val command = tradeToEntry(entryId, event)
            val applied = repo.appendEntry(command)
            metrics.observeLedgerAppendLatency(nanosToMillis(started))
            if (!applied) {
                metrics.incrementUniqueViolation()
                log.info("service=ledger msg=duplicate_trade trade_id={}", event.tradeId)
                return SettlementResult(applied = false, entryId = entryId, reason = "duplicate")
            }

            repo.updateSettledSeq(event.envelope.symbol, event.envelope.seq)
            val lagMs = Duration.between(event.envelope.occurredAt, Instant.now()).toMillis()
            metrics.observeSettlementLag(lagMs)
            refreshReserveMetrics()
            log.info("service=ledger msg=settled trade_id={} seq={}", event.tradeId, event.envelope.seq)
            SettlementResult(applied = true, entryId = entryId, reason = "applied")
        } catch (ex: Exception) {
            metrics.incrementSettlementRetry()
            metrics.incrementDlq()
            repo.appendDlq(event.tradeId, ex.message ?: "unknown", tradePayload(event))
            log.error("service=ledger msg=settlement_failed trade_id={} reason={}", event.tradeId, ex.message)
            SettlementResult(applied = false, entryId = entryId, reason = "dlq")
        }
    }

    fun reserve(command: ReserveCommand): Boolean {
        require(command.amount > 0) { "reserve amount must be > 0" }
        val parts = parseSymbol(command.envelope.symbol)
        val side = command.side.uppercase()
        val currency = if (side == "BUY") parts.quote else parts.base
        val available = userAccount(command.userId, currency, "AVAILABLE")
        val hold = userAccount(command.userId, currency, "HOLD")
        val entry = LedgerEntryCommand(
            entryId = "le_reserve_${command.orderId}",
            referenceType = "ORDER",
            referenceId = command.orderId,
            entryKind = "RESERVE",
            symbol = command.envelope.symbol,
            engineSeq = command.envelope.seq,
            occurredAt = command.envelope.occurredAt,
            correlationId = command.envelope.correlationId,
            causationId = command.envelope.causationId,
            postings = listOf(
                LedgerPostingCommand(accountId = hold, currency = currency, amount = command.amount, isDebit = true),
                LedgerPostingCommand(accountId = available, currency = currency, amount = command.amount, isDebit = false),
            ),
        )
        val applied = repo.appendEntry(entry)
        if (!applied) {
            metrics.incrementUniqueViolation()
        }
        refreshReserveMetrics()
        return applied
    }

    fun release(command: ReserveCommand): Boolean {
        require(command.amount > 0) { "release amount must be > 0" }
        val parts = parseSymbol(command.envelope.symbol)
        val side = command.side.uppercase()
        val currency = if (side == "BUY") parts.quote else parts.base
        val available = userAccount(command.userId, currency, "AVAILABLE")
        val hold = userAccount(command.userId, currency, "HOLD")
        val entry = LedgerEntryCommand(
            entryId = "le_release_${command.orderId}",
            referenceType = "ORDER",
            referenceId = command.orderId,
            entryKind = "RELEASE",
            symbol = command.envelope.symbol,
            engineSeq = command.envelope.seq,
            occurredAt = command.envelope.occurredAt,
            correlationId = command.envelope.correlationId,
            causationId = command.envelope.causationId,
            postings = listOf(
                LedgerPostingCommand(accountId = available, currency = currency, amount = command.amount, isDebit = true),
                LedgerPostingCommand(accountId = hold, currency = currency, amount = command.amount, isDebit = false),
            ),
        )
        val applied = repo.appendEntry(entry)
        if (!applied) {
            metrics.incrementUniqueViolation()
        }
        refreshReserveMetrics()
        return applied
    }

    fun adjustAvailable(command: BalanceAdjustmentCommand): Boolean {
        require(command.amountDelta != 0L) { "amount_delta must not be 0" }
        val amount = kotlin.math.abs(command.amountDelta)
        val user = userAccount(command.userId, command.currency, "AVAILABLE")
        val treasury = systemAccount("treasury", command.currency)
        val postings = if (command.amountDelta > 0) {
            listOf(
                LedgerPostingCommand(accountId = user, currency = command.currency, amount = amount, isDebit = true),
                LedgerPostingCommand(accountId = treasury, currency = command.currency, amount = amount, isDebit = false),
            )
        } else {
            listOf(
                LedgerPostingCommand(accountId = treasury, currency = command.currency, amount = amount, isDebit = true),
                LedgerPostingCommand(accountId = user, currency = command.currency, amount = amount, isDebit = false),
            )
        }

        val entry = LedgerEntryCommand(
            entryId = "le_adj_${command.referenceId}",
            referenceType = "ADJUSTMENT",
            referenceId = command.referenceId,
            entryKind = "MANUAL_ADJUSTMENT",
            symbol = command.envelope.symbol,
            engineSeq = command.envelope.seq,
            occurredAt = command.envelope.occurredAt,
            correlationId = command.envelope.correlationId,
            causationId = command.envelope.causationId,
            postings = postings,
        )
        val started = System.nanoTime()
        val applied = repo.appendEntry(entry)
        metrics.observeLedgerAppendLatency(nanosToMillis(started))
        if (!applied) {
            metrics.incrementUniqueViolation()
        }
        refreshReserveMetrics()
        return applied
    }

    fun updateEngineSeq(symbol: String, seq: Long) {
        repo.updateEngineSeq(symbol, seq)
        reconciliation(symbol)
    }

    fun observeEngineSeq(symbol: String, seq: Long) {
        repo.updateEngineSeq(symbol, seq)
    }

    fun reconciliation(symbol: String): ReconciliationStatus {
        val status = repo.reconciliation(symbol)
        val ageMs = status.updatedAt?.let { Duration.between(it, Instant.now()).toMillis() } ?: 0L
        metrics.setReconciliation(status.gap, ageMs)
        return status
    }

    fun reconciliationAll(): List<ReconciliationStatus> {
        val statuses = repo.reconciliationAll()
        val maxLag = statuses.maxOfOrNull { it.gap.coerceAtLeast(0) } ?: 0L
        metrics.setReconciliationSummary(maxLag = maxLag, activeBreaches = 0)
        return statuses
    }

    fun runReconciliationEvaluation(
        lagThreshold: Long,
        safetyMode: SafetyMode,
        autoSwitchEnabled: Boolean,
        safetyLatchEnabled: Boolean,
    ): ReconciliationRunSummary {
        val checkedAt = Instant.now()
        val statuses = repo.reconciliationAll()
        val existingSafety = repo.reconciliationSafetyStates()
        val evaluations = mutableListOf<ReconciliationEvaluation>()
        var activeBreaches = 0L
        var maxLag = 0L

        statuses.forEach { status ->
            val lag = status.lastEngineSeq - status.lastSettledSeq
            val mismatch = lag < 0
            val thresholdBreached = lag > lagThreshold
            val breached = mismatch || thresholdBreached
            val reason = reconciliationReason(mismatch, thresholdBreached)
            val prev = existingSafety[status.symbol]
            val latchEngaged = if (safetyLatchEnabled) (prev?.latchEngaged == true || breached) else false
            val effectiveBreachActive = if (latchEngaged) true else breached
            val effectiveReason = if (!breached && latchEngaged) "MANUAL_RELEASE_REQUIRED" else reason
            val latchUpdatedAt = when {
                !latchEngaged -> null
                prev?.latchEngaged == true && !breached -> prev.latchUpdatedAt ?: checkedAt
                else -> checkedAt
            }
            val latchReason = when {
                !latchEngaged -> null
                breached -> reason
                else -> prev?.latchReason ?: "MANUAL_RELEASE_REQUIRED"
            }
            if (mismatch) {
                metrics.incrementReconciliationMismatch()
            }

            val shouldTrigger = breached && (prev == null || !prev.breachActive)
            var safetyActionTaken = false
            var actionAt: Instant? = prev?.lastActionAt

            if (shouldTrigger) {
                metrics.incrementReconciliationAlert()
                if (autoSwitchEnabled) {
                    safetyActionTaken = symbolModeSwitcher.setSymbolMode(status.symbol, safetyMode, reason)
                    if (safetyActionTaken) {
                        actionAt = checkedAt
                        metrics.incrementReconciliationSafetyTrigger()
                    } else {
                        metrics.incrementReconciliationSafetyFailure()
                    }
                }
            }

            if (effectiveBreachActive) {
                activeBreaches += 1
            }
            if (lag > maxLag) {
                maxLag = lag
            }

            val evaluation = ReconciliationEvaluation(
                symbol = status.symbol,
                lastEngineSeq = status.lastEngineSeq,
                lastSettledSeq = status.lastSettledSeq,
                lag = lag,
                mismatch = mismatch,
                threshold = lagThreshold,
                breached = breached,
                reason = effectiveReason,
                safetyMode = safetyMode,
                safetyActionTaken = safetyActionTaken,
                checkedAt = checkedAt,
            )
            repo.recordReconciliationHistory(evaluation)
            repo.upsertReconciliationSafetyState(
                symbol = status.symbol,
                breachActive = effectiveBreachActive,
                lag = lag,
                mismatch = mismatch,
                safetyMode = if (breached) safetyMode.name else prev?.safetyMode,
                actionTaken = safetyActionTaken,
                reason = effectiveReason,
                updatedAt = checkedAt,
                lastActionAt = actionAt,
                latchEngaged = latchEngaged,
                latchReason = latchReason,
                latchUpdatedAt = latchUpdatedAt,
                latchReleasedAt = if (latchEngaged) null else prev?.latchReleasedAt,
                latchReleasedBy = if (latchEngaged) null else prev?.latchReleasedBy,
            )
            evaluations += evaluation
        }

        metrics.setReconciliationSummary(maxLag = maxLag.coerceAtLeast(0), activeBreaches = activeBreaches)
        return ReconciliationRunSummary(checkedAt = checkedAt, evaluations = evaluations)
    }

    fun reconciliationStatus(historyLimit: Int, lagThreshold: Long): ReconciliationDashboard {
        val now = Instant.now()
        val statuses = repo.reconciliationAll()
        val safetyStates = repo.reconciliationSafetyStates()
        val views = statuses.map { status ->
            val lag = status.lastEngineSeq - status.lastSettledSeq
            val mismatch = lag < 0
            val thresholdBreached = lag > lagThreshold
            val safety = safetyStates[status.symbol]
            ReconciliationStatusView(
                symbol = status.symbol,
                lastEngineSeq = status.lastEngineSeq,
                lastSettledSeq = status.lastSettledSeq,
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                breached = (mismatch || thresholdBreached),
                breachActive = safety?.breachActive ?: false,
                safetyMode = safety?.safetyMode,
                lastActionAt = safety?.lastActionAt,
                latchEngaged = safety?.latchEngaged ?: false,
                latchReason = safety?.latchReason,
                latchUpdatedAt = safety?.latchUpdatedAt,
                latchReleasedAt = safety?.latchReleasedAt,
                latchReleasedBy = safety?.latchReleasedBy,
                updatedAt = status.updatedAt,
            )
        }
        val history = repo.reconciliationHistory(historyLimit)
        return ReconciliationDashboard(
            checkedAt = now,
            statuses = views,
            history = history,
        )
    }

    fun activateSafetyModeForTrackedSymbols(mode: SafetyMode, reason: String): SafetyModeActivationSummary {
        val symbols = repo.trackedSymbols().filter { it.isNotBlank() }
        if (symbols.isEmpty()) {
            return SafetyModeActivationSummary(
                requestedSymbols = emptyList(),
                switchedSymbols = emptyList(),
                failedSymbols = emptyList(),
            )
        }

        val switched = mutableListOf<String>()
        val failed = mutableListOf<String>()
        symbols.forEach { symbol ->
            val ok = symbolModeSwitcher.setSymbolMode(symbol, mode, reason)
            if (ok) {
                switched += symbol
            } else {
                failed += symbol
            }
        }

        metrics.incrementInvariantSafetyTrigger(switched.size.toLong())
        metrics.incrementInvariantSafetyFailure(failed.size.toLong())
        return SafetyModeActivationSummary(
            requestedSymbols = symbols,
            switchedSymbols = switched,
            failedSymbols = failed,
        )
    }

    fun releaseReconciliationLatch(
        symbol: String,
        lagThreshold: Long,
        approvedBy: String,
        reason: String,
        restoreSymbolMode: Boolean,
        allowNegativeBalanceViolations: Boolean,
    ): ReconciliationLatchReleaseResult {
        val safeSymbol = symbol.trim().uppercase()
        val status = repo.reconciliation(safeSymbol)
        val lag = status.lastEngineSeq - status.lastSettledSeq
        val mismatch = lag < 0
        val thresholdBreached = lag > lagThreshold
        if (mismatch || thresholdBreached) {
            return ReconciliationLatchReleaseResult(
                symbol = safeSymbol,
                released = false,
                modeRestored = false,
                reason = "still_breached",
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                invariantsOk = false,
                invariantViolations = emptyList(),
                releasedAt = null,
                releasedBy = null,
            )
        }

        val safety = repo.reconciliationSafetyState(safeSymbol)
            ?: return ReconciliationLatchReleaseResult(
                symbol = safeSymbol,
                released = false,
                modeRestored = false,
                reason = "safety_state_not_found",
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                invariantsOk = false,
                invariantViolations = emptyList(),
                releasedAt = null,
                releasedBy = null,
            )
        if (!safety.latchEngaged) {
            return ReconciliationLatchReleaseResult(
                symbol = safeSymbol,
                released = false,
                modeRestored = false,
                reason = "latch_not_engaged",
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                invariantsOk = false,
                invariantViolations = emptyList(),
                releasedAt = null,
                releasedBy = null,
            )
        }

        val invariantResult = runInvariantCheck()
        val negativeOnlyViolation = invariantResult.violations.isNotEmpty() &&
            invariantResult.violations.all { it.startsWith("negative_balances=") }
        val invariantGatePass = invariantResult.ok || (allowNegativeBalanceViolations && negativeOnlyViolation)
        if (!invariantGatePass) {
            return ReconciliationLatchReleaseResult(
                symbol = safeSymbol,
                released = false,
                modeRestored = false,
                reason = "invariants_failed",
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                invariantsOk = false,
                invariantViolations = invariantResult.violations,
                releasedAt = null,
                releasedBy = null,
            )
        }

        val releasedAt = Instant.now()
        val modeRestored = if (restoreSymbolMode) {
            symbolModeSwitcher.restoreSymbolMode(safeSymbol, "reconciliation_latch_release:$reason")
        } else {
            false
        }
        if (restoreSymbolMode && !modeRestored) {
            return ReconciliationLatchReleaseResult(
                symbol = safeSymbol,
                released = false,
                modeRestored = false,
                reason = "mode_restore_failed",
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                invariantsOk = invariantResult.ok,
                invariantViolations = invariantResult.violations,
                releasedAt = null,
                releasedBy = null,
            )
        }

        val nextMode = if (restoreSymbolMode) "NORMAL" else safety.safetyMode
        val releaseReason = "manual_latch_release:$reason"
        val released = repo.releaseReconciliationLatch(
            symbol = safeSymbol,
            lag = lag,
            mismatch = mismatch,
            safetyMode = nextMode,
            releaseReason = releaseReason,
            releasedBy = approvedBy,
            releasedAt = releasedAt,
        )
        if (!released) {
            return ReconciliationLatchReleaseResult(
                symbol = safeSymbol,
                released = false,
                modeRestored = modeRestored,
                reason = "release_not_applied",
                lag = lag,
                mismatch = mismatch,
                thresholdBreached = thresholdBreached,
                invariantsOk = invariantResult.ok,
                invariantViolations = invariantResult.violations,
                releasedAt = null,
                releasedBy = null,
            )
        }

        repo.recordReconciliationHistory(
            ReconciliationEvaluation(
                symbol = safeSymbol,
                lastEngineSeq = status.lastEngineSeq,
                lastSettledSeq = status.lastSettledSeq,
                lag = lag,
                mismatch = mismatch,
                threshold = lagThreshold,
                breached = false,
                reason = releaseReason,
                safetyMode = SafetyMode.parse(nextMode ?: "CANCEL_ONLY"),
                safetyActionTaken = modeRestored,
                checkedAt = releasedAt,
            ),
        )
        val refreshedStatuses = repo.reconciliationAll()
        val refreshedSafety = repo.reconciliationSafetyStates()
        val maxLag = refreshedStatuses.maxOfOrNull { it.gap.coerceAtLeast(0) } ?: 0L
        val activeBreaches = refreshedSafety.values.count { it.breachActive }.toLong()
        metrics.setReconciliationSummary(maxLag = maxLag, activeBreaches = activeBreaches)

        return ReconciliationLatchReleaseResult(
            symbol = safeSymbol,
            released = true,
            modeRestored = modeRestored,
            reason = releaseReason,
            lag = lag,
            mismatch = mismatch,
            thresholdBreached = thresholdBreached,
            invariantsOk = invariantResult.ok,
            invariantViolations = invariantResult.violations,
            releasedAt = releasedAt,
            releasedBy = approvedBy,
        )
    }

    fun runInvariantCheck(): InvariantCheckResult {
        val started = System.nanoTime()
        val result = repo.invariantCheck()
        metrics.observeBalanceComputeLag(nanosToMillis(started))
        if (!result.ok) {
            metrics.incrementInvariantViolation()
            log.error("service=ledger msg=invariant_violation violations={}", result.violations.joinToString(","))
        }
        return result
    }

    fun rebuildBalances() {
        val started = System.nanoTime()
        repo.rebuildBalances()
        metrics.observeRebuildDuration(nanosToMillis(started))
        refreshReserveMetrics()
    }

    fun createCorrection(
        correctionId: String,
        originalEntryId: String,
        mode: String,
        reason: String,
        ticketId: String,
        requestedBy: String,
    ) {
        repo.createCorrectionRequest(correctionId, originalEntryId, mode.uppercase(), reason, ticketId, requestedBy)
        refreshCorrectionPendingAge()
    }

    fun approveCorrection(correctionId: String, approver: String): CorrectionRequest {
        val result = repo.approveCorrection(correctionId, approver)
        refreshCorrectionPendingAge()
        return result
    }

    fun applyCorrection(correctionId: String, envelope: EventEnvelope): SettlementResult {
        val correction = repo.getCorrection(correctionId)
        if (correction.status == "APPLIED") {
            return SettlementResult(applied = false, entryId = "le_corr_$correctionId", reason = "already_applied")
        }
        if (correction.status != "APPROVED") {
            return SettlementResult(applied = false, entryId = "le_corr_$correctionId", reason = "not_approved")
        }

        val applied = when (correction.mode.uppercase()) {
            "REVERSAL" -> repo.reverseEntry(
                originalEntryId = correction.originalEntryId,
                correctionEntryId = "le_corr_$correctionId",
                correlationId = envelope.correlationId,
                causationId = envelope.causationId,
            )
            else -> throw IllegalArgumentException("mode ${correction.mode} not supported in v1")
        }

        if (applied) {
            repo.markCorrectionApplied(correctionId)
            metrics.incrementCorrections()
            refreshCorrectionPendingAge()
            refreshReserveMetrics()
            return SettlementResult(applied = true, entryId = "le_corr_$correctionId", reason = "applied")
        }
        metrics.incrementUniqueViolation()
        return SettlementResult(applied = false, entryId = "le_corr_$correctionId", reason = "duplicate")
    }

    fun listBalances(): Map<String, Long> = repo.listBalances()

    fun findTrade(tradeId: String): TradeLookup? = repo.findTrade(tradeId)

    private fun tradeToEntry(entryId: String, event: TradeExecuted): LedgerEntryCommand {
        require(event.price > 0) { "price must be > 0" }
        require(event.quantity > 0) { "quantity must be > 0" }
        require(event.feeBuyer >= 0 && event.feeSeller >= 0) { "fees must be >= 0" }

        val parts = parseSymbol(event.envelope.symbol)
        val quoteAmount = if (event.quoteAmount > 0) {
            event.quoteAmount
        } else {
            Math.multiplyExact(event.price, event.quantity)
        }
        val buyerGrossQuote = Math.addExact(quoteAmount, event.feeBuyer)
        val sellerNetQuote = quoteAmount - event.feeSeller
        require(sellerNetQuote >= 0) { "fee_seller exceeds quote amount" }

        val buyerQuoteHold = userAccount(event.buyerUserId, parts.quote, "HOLD")
        val sellerQuoteAvailable = userAccount(event.sellerUserId, parts.quote, "AVAILABLE")
        val buyerBaseAvailable = userAccount(event.buyerUserId, parts.base, "AVAILABLE")
        val sellerBaseHold = userAccount(event.sellerUserId, parts.base, "HOLD")
        val feeAccount = systemAccount("fees", parts.quote)

        val postings = mutableListOf(
            LedgerPostingCommand(accountId = sellerQuoteAvailable, currency = parts.quote, amount = sellerNetQuote, isDebit = true),
            LedgerPostingCommand(accountId = buyerQuoteHold, currency = parts.quote, amount = buyerGrossQuote, isDebit = false),
            LedgerPostingCommand(accountId = buyerBaseAvailable, currency = parts.base, amount = event.quantity, isDebit = true),
            LedgerPostingCommand(accountId = sellerBaseHold, currency = parts.base, amount = event.quantity, isDebit = false),
        )
        val totalFee = Math.addExact(event.feeBuyer, event.feeSeller)
        if (totalFee > 0) {
            postings += LedgerPostingCommand(accountId = feeAccount, currency = parts.quote, amount = totalFee, isDebit = true)
        }

        return LedgerEntryCommand(
            entryId = entryId,
            referenceType = "TRADE",
            referenceId = event.tradeId,
            entryKind = "FILL",
            symbol = event.envelope.symbol,
            engineSeq = event.envelope.seq,
            occurredAt = event.envelope.occurredAt,
            correlationId = event.envelope.correlationId,
            causationId = event.envelope.causationId,
            postings = postings,
        )
    }

    private fun userAccount(userId: String, currency: String, kind: String): String {
        return "user:$userId:$currency:${kind.uppercase()}"
    }

    private fun systemAccount(name: String, currency: String): String {
        return "system:$name:$currency:AVAILABLE"
    }

    private fun tradePayload(event: TradeExecuted): String {
        return "trade_id=${event.tradeId},symbol=${event.envelope.symbol},seq=${event.envelope.seq}"
    }

    private fun refreshReserveMetrics() {
        val totals = repo.balanceTotalsByKind()
        metrics.setReserveAvailable(
            reserved = totals["HOLD"] ?: 0L,
            available = totals["AVAILABLE"] ?: 0L,
        )
    }

    private fun refreshCorrectionPendingAge() {
        val oldest = repo.oldestPendingCorrectionCreatedAt()
        val ageMs = oldest?.let { Duration.between(it, Instant.now()).toMillis() } ?: 0L
        metrics.setCorrectionPendingAgeMs(ageMs)
    }

    private fun reconciliationReason(mismatch: Boolean, thresholdBreached: Boolean): String {
        return when {
            mismatch -> "settled_seq_ahead_of_engine_seq"
            thresholdBreached -> "lag_threshold_exceeded"
            else -> "within_threshold"
        }
    }

    private fun nanosToMillis(started: Long): Long {
        return (System.nanoTime() - started) / 1_000_000
    }
}
