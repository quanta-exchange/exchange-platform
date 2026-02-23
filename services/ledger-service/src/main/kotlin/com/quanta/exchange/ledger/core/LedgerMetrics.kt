package com.quanta.exchange.ledger.core

import org.springframework.stereotype.Component
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

@Component
class LedgerMetrics {
    private val ledgerAppendLatencyMs = AtomicLong(0)
    private val uniqueViolationTotal = AtomicLong(0)
    private val settlementLagMs = AtomicLong(0)
    private val settlementRetryTotal = AtomicLong(0)
    private val dlqTotal = AtomicLong(0)
    private val reservedTotal = AtomicLong(0)
    private val availableTotal = AtomicLong(0)
    private val invariantViolationTotal = AtomicLong(0)
    private val balanceComputeLagMs = AtomicLong(0)
    private val rebuildDurationMs = AtomicLong(0)
    private val reconciliationGap = AtomicLong(0)
    private val gapAgeMs = AtomicLong(0)
    private val correctionsTotal = AtomicLong(0)
    private val correctionPendingAgeMs = AtomicLong(0)
    private val reconciliationLagMax = AtomicLong(0)
    private val reconciliationBreachActive = AtomicLong(0)
    private val reconciliationAlertTotal = AtomicLong(0)
    private val reconciliationMismatchTotal = AtomicLong(0)
    private val reconciliationStaleTotal = AtomicLong(0)
    private val reconciliationSafetyTriggerTotal = AtomicLong(0)
    private val reconciliationSafetyFailureTotal = AtomicLong(0)
    private val invariantSafetyTriggerTotal = AtomicLong(0)
    private val invariantSafetyFailureTotal = AtomicLong(0)
    private val reconciliationLatchReleaseAttemptTotal = AtomicLong(0)
    private val reconciliationLatchReleaseSuccessTotal = AtomicLong(0)
    private val reconciliationLatchReleaseDeniedTotal = AtomicLong(0)
    private val reconciliationLatchReleaseDeniedByReason = ConcurrentHashMap<String, AtomicLong>()
    private val reconciliationGapBySymbol = ConcurrentHashMap<String, AtomicLong>()
    private val reconciliationAgeBySymbol = ConcurrentHashMap<String, AtomicLong>()

    fun observeLedgerAppendLatency(ms: Long) = ledgerAppendLatencyMs.set(ms.coerceAtLeast(0))
    fun incrementUniqueViolation() = uniqueViolationTotal.incrementAndGet()
    fun observeSettlementLag(ms: Long) = settlementLagMs.set(ms.coerceAtLeast(0))
    fun incrementSettlementRetry() = settlementRetryTotal.incrementAndGet()
    fun incrementDlq() = dlqTotal.incrementAndGet()
    fun setReserveAvailable(reserved: Long, available: Long) {
        reservedTotal.set(reserved)
        availableTotal.set(available)
    }
    fun incrementInvariantViolation() = invariantViolationTotal.incrementAndGet()
    fun observeBalanceComputeLag(ms: Long) = balanceComputeLagMs.set(ms.coerceAtLeast(0))
    fun observeRebuildDuration(ms: Long) = rebuildDurationMs.set(ms.coerceAtLeast(0))
    fun setReconciliation(gap: Long, ageMs: Long) {
        reconciliationGap.set(gap.coerceAtLeast(0))
        gapAgeMs.set(ageMs.coerceAtLeast(0))
    }
    fun setReconciliationBySymbol(symbol: String, gap: Long, ageMs: Long) {
        val normalized = symbol.trim().uppercase()
        if (normalized.isBlank()) {
            return
        }
        reconciliationGapBySymbol.computeIfAbsent(normalized) { AtomicLong(0) }.set(gap.coerceAtLeast(0))
        reconciliationAgeBySymbol.computeIfAbsent(normalized) { AtomicLong(0) }.set(ageMs.coerceAtLeast(0))
    }
    fun incrementCorrections() = correctionsTotal.incrementAndGet()
    fun setCorrectionPendingAgeMs(ms: Long) = correctionPendingAgeMs.set(ms.coerceAtLeast(0))
    fun setReconciliationSummary(maxLag: Long, activeBreaches: Long) {
        reconciliationLagMax.set(maxLag.coerceAtLeast(0))
        reconciliationBreachActive.set(activeBreaches.coerceAtLeast(0))
    }
    fun incrementReconciliationAlert() = reconciliationAlertTotal.incrementAndGet()
    fun incrementReconciliationMismatch() = reconciliationMismatchTotal.incrementAndGet()
    fun incrementReconciliationStale() = reconciliationStaleTotal.incrementAndGet()
    fun incrementReconciliationSafetyTrigger() = reconciliationSafetyTriggerTotal.incrementAndGet()
    fun incrementReconciliationSafetyFailure() = reconciliationSafetyFailureTotal.incrementAndGet()
    fun incrementInvariantSafetyTrigger(delta: Long = 1) {
        if (delta > 0) {
            invariantSafetyTriggerTotal.addAndGet(delta)
        }
    }
    fun incrementInvariantSafetyFailure(delta: Long = 1) {
        if (delta > 0) {
            invariantSafetyFailureTotal.addAndGet(delta)
        }
    }
    fun incrementReconciliationLatchReleaseAttempt() = reconciliationLatchReleaseAttemptTotal.incrementAndGet()
    fun incrementReconciliationLatchReleaseSuccess() = reconciliationLatchReleaseSuccessTotal.incrementAndGet()
    fun incrementReconciliationLatchReleaseDenied(reason: String) {
        reconciliationLatchReleaseDeniedTotal.incrementAndGet()
        val normalized = reason.trim().lowercase().ifBlank { "unknown" }
        reconciliationLatchReleaseDeniedByReason.computeIfAbsent(normalized) { AtomicLong(0) }.incrementAndGet()
    }

    fun renderPrometheus(): String {
        return buildString {
            appendMetric("ledger_append_latency_ms", ledgerAppendLatencyMs.get())
            appendMetric("unique_violation_total", uniqueViolationTotal.get())
            appendMetric("settlement_lag_ms", settlementLagMs.get())
            appendMetric("settlement_retry_total", settlementRetryTotal.get())
            appendMetric("dlq_total", dlqTotal.get())
            appendMetric("reserved_total", reservedTotal.get())
            appendMetric("available_total", availableTotal.get())
            appendMetric("invariant_violation_total", invariantViolationTotal.get())
            appendMetric("balance_compute_lag_ms", balanceComputeLagMs.get())
            appendMetric("rebuild_duration_ms", rebuildDurationMs.get())
            appendMetric("reconciliation_gap", reconciliationGap.get())
            appendMetric("gap_age_ms", gapAgeMs.get())
            appendMetric("corrections_total", correctionsTotal.get())
            appendMetric("correction_pending_age", correctionPendingAgeMs.get())
            appendMetric("reconciliation_lag_max", reconciliationLagMax.get())
            appendMetric("reconciliation_breach_active", reconciliationBreachActive.get())
            appendMetric("reconciliation_alert_total", reconciliationAlertTotal.get())
            appendMetric("reconciliation_mismatch_total", reconciliationMismatchTotal.get())
            appendMetric("reconciliation_stale_total", reconciliationStaleTotal.get())
            appendMetric("reconciliation_safety_trigger_total", reconciliationSafetyTriggerTotal.get())
            appendMetric("reconciliation_safety_failure_total", reconciliationSafetyFailureTotal.get())
            appendMetric("invariant_safety_trigger_total", invariantSafetyTriggerTotal.get())
            appendMetric("invariant_safety_failure_total", invariantSafetyFailureTotal.get())
            appendMetric("reconciliation_latch_release_attempt_total", reconciliationLatchReleaseAttemptTotal.get())
            appendMetric("reconciliation_latch_release_success_total", reconciliationLatchReleaseSuccessTotal.get())
            appendMetric("reconciliation_latch_release_denied_total", reconciliationLatchReleaseDeniedTotal.get())
            appendReconciliationLatchDeniedByReason()
            appendReconciliationBySymbol()
        }
    }

    private fun StringBuilder.appendReconciliationLatchDeniedByReason() {
        reconciliationLatchReleaseDeniedByReason.entries
            .sortedBy { it.key }
            .forEach { (reason, value) ->
                appendMetricWithLabel("reconciliation_latch_release_denied_reason_total", "reason", reason, value.get())
            }
    }

    private fun StringBuilder.appendReconciliationBySymbol() {
        val symbols = (reconciliationGapBySymbol.keys + reconciliationAgeBySymbol.keys).sorted()
        symbols.forEach { symbol ->
            appendMetricWithLabel("reconciliation_gap_by_symbol", "symbol", symbol, reconciliationGapBySymbol[symbol]?.get() ?: 0)
            appendMetricWithLabel("reconciliation_age_ms_by_symbol", "symbol", symbol, reconciliationAgeBySymbol[symbol]?.get() ?: 0)
        }
    }

    private fun StringBuilder.appendMetric(name: String, value: Long) {
        append(name)
        append(' ')
        append(value)
        append('\n')
    }

    private fun StringBuilder.appendMetricWithLabel(name: String, label: String, labelValue: String, value: Long) {
        append(name)
        append('{')
        append(label)
        append("=\"")
        append(escapeLabel(labelValue))
        append("\"}")
        append(' ')
        append(value)
        append('\n')
    }

    private fun escapeLabel(value: String): String {
        return value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
    }
}
