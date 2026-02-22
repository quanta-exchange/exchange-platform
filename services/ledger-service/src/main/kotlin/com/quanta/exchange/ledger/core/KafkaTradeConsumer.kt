package com.quanta.exchange.ledger.core

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.DeserializationFeature
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule
import com.fasterxml.jackson.module.kotlin.registerKotlinModule
import com.quanta.exchange.ledger.api.TradeExecutedDto
import org.slf4j.LoggerFactory
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.kafka.annotation.KafkaListener
import org.springframework.stereotype.Component

@Component
@ConditionalOnProperty(prefix = "ledger.kafka", name = ["enabled"], havingValue = "true")
class KafkaTradeConsumer(
    private val ledgerService: LedgerService,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val mapper: ObjectMapper = ObjectMapper()
        .registerKotlinModule()
        .registerModule(JavaTimeModule())
        .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)

    @KafkaListener(
        id = "ledger-settlement-consumer",
        topics = ["\${ledger.kafka.trade-topic:core.trade-events.v1}"],
        groupId = "\${ledger.kafka.group-id:ledger-settlement-v1}",
        autoStartup = "\${ledger.kafka.settlement-enabled:true}",
    )
    fun onMessage(payload: String) {
        try {
            val trade = mapper.readValue(payload, TradeExecutedDto::class.java)
            val result = ledgerService.consumeTrade(trade.toModel())
            if (!result.applied) {
                log.warn("service=ledger msg=consumer_not_applied reason={} entry_id={}", result.reason, result.entryId)
            }
        } catch (ex: Exception) {
            log.error("service=ledger msg=consumer_parse_failed reason={}", ex.message)
            throw ex
        }
    }
}
