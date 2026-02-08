package com.quanta.exchange.ledger.core

import org.springframework.stereotype.Component
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
    fun incrementCorrections() = correctionsTotal.incrementAndGet()
    fun setCorrectionPendingAgeMs(ms: Long) = correctionPendingAgeMs.set(ms.coerceAtLeast(0))

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
        }
    }

    private fun StringBuilder.appendMetric(name: String, value: Long) {
        append(name)
        append(' ')
        append(value)
        append('\n')
    }
}
