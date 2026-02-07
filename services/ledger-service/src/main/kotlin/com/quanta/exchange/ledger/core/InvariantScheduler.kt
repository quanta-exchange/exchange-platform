package com.quanta.exchange.ledger.core

import org.slf4j.LoggerFactory
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.scheduling.annotation.Scheduled
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(prefix = "ledger.guard", name = ["enabled"], havingValue = "true", matchIfMissing = true)
class InvariantScheduler(
    private val ledgerService: LedgerService,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @Scheduled(fixedDelayString = "\${ledger.guard.interval-ms:30000}")
    fun evaluate() {
        val result = ledgerService.runInvariantCheck()
        if (!result.ok) {
            log.error("service=ledger msg=invariant_scheduler_alert violations={}", result.violations.joinToString(","))
        }
    }
}
