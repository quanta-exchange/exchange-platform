package com.quanta.exchange.ledger.core

import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(prefix = "ledger.guard", name = ["enabled"], havingValue = "true", matchIfMissing = true)
class InvariantScheduler(
    private val ledgerService: LedgerService,
    @Value("\${ledger.guard.auto-switch-enabled:true}")
    private val autoSwitchEnabled: Boolean,
    @Value("\${ledger.guard.safety-mode:CANCEL_ONLY}")
    private val safetyMode: String,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @Scheduled(fixedDelayString = "\${ledger.guard.interval-ms:30000}")
    fun evaluate() {
        val result = ledgerService.runInvariantCheck()
        if (!result.ok) {
            log.error("service=ledger msg=invariant_scheduler_alert violations={}", result.violations.joinToString(","))
            if (autoSwitchEnabled) {
                val mode = SafetyMode.parse(safetyMode)
                val reason = "invariant_violation:${result.violations.joinToString("|")}"
                val switched = ledgerService.activateSafetyModeForTrackedSymbols(mode, reason)
                log.error(
                    "service=ledger msg=invariant_scheduler_safety symbols={} switched={} failed={} mode={}",
                    switched.requestedSymbols.joinToString(","),
                    switched.switchedSymbols.joinToString(","),
                    switched.failedSymbols.joinToString(","),
                    mode.name,
                )
            }
        }
    }
}
