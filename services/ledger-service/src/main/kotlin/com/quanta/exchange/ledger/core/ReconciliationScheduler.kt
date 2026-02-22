package com.quanta.exchange.ledger.core

import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(prefix = "ledger.reconciliation", name = ["enabled"], havingValue = "true", matchIfMissing = true)
class ReconciliationScheduler(
    private val ledgerService: LedgerService,
    @Value("\${ledger.reconciliation.lag-threshold:10}")
    private val lagThreshold: Long,
    @Value("\${ledger.reconciliation.safety-mode:CANCEL_ONLY}")
    private val safetyMode: String,
    @Value("\${ledger.reconciliation.auto-switch-enabled:true}")
    private val autoSwitchEnabled: Boolean,
    @Value("\${ledger.reconciliation.safety-latch-enabled:true}")
    private val safetyLatchEnabled: Boolean,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @Scheduled(fixedDelayString = "\${ledger.reconciliation.interval-ms:5000}")
    fun evaluate() {
        val mode = SafetyMode.parse(safetyMode)
        val result = ledgerService.runReconciliationEvaluation(
            lagThreshold = lagThreshold.coerceAtLeast(0),
            safetyMode = mode,
            autoSwitchEnabled = autoSwitchEnabled,
            safetyLatchEnabled = safetyLatchEnabled,
        )
        val breached = result.evaluations.filter { it.breached }
        if (breached.isNotEmpty()) {
            log.error(
                "service=ledger msg=reconciliation_breach symbols={} mode={} threshold={}",
                breached.joinToString(",") { it.symbol },
                mode.name,
                lagThreshold,
            )
        }
    }
}
