package com.quanta.exchange.ledger.core

import com.fasterxml.jackson.databind.DeserializationFeature
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule
import com.fasterxml.jackson.module.kotlin.registerKotlinModule
import com.quanta.exchange.ledger.api.TradeExecutedDto
import org.slf4j.LoggerFactory
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(prefix = "ledger.kafka", name = ["enabled"], havingValue = "true")
class KafkaReconciliationObserver(
    private val ledgerService: LedgerService,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val mapper: ObjectMapper = ObjectMapper()
        .registerKotlinModule()
        .registerModule(JavaTimeModule())
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)

    @KafkaListener(
        id = "ledger-reconciliation-observer",
        topics = ["\${ledger.kafka.trade-topic:core.trade-events.v1}"],
        groupId = "\${ledger.kafka.reconciliation-group-id:ledger-reconciliation-v1}",
        autoStartup = "\${ledger.kafka.reconciliation-observer-enabled:true}",
    )
    fun observe(payload: String) {
        try {
            val trade = mapper.readValue(payload, TradeExecutedDto::class.java)
            ledgerService.observeEngineSeq(trade.envelope.symbol, trade.envelope.seq)
        } catch (ex: Exception) {
            log.error("service=ledger msg=reconciliation_observer_parse_failed reason={}", ex.message)
            throw ex
        }
    }
}

