package com.quanta.exchange.ledger

import com.quanta.exchange.ledger.api.SystemController
import com.quanta.exchange.ledger.core.ConsumerControlStatus
import com.quanta.exchange.ledger.core.KafkaConsumerControl
import com.quanta.exchange.ledger.core.LedgerMetrics
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.mockito.Mockito.`when`
import org.mockito.Mockito.mock
import org.springframework.http.HttpStatus
import org.springframework.jdbc.core.JdbcTemplate

class SystemControllerTest {
    @Test
    fun readyReturnsDbUnreadyWhenDatabasePingFails() {
        val jdbc = mock(JdbcTemplate::class.java)
        `when`(jdbc.queryForObject("SELECT 1", Int::class.java)).thenThrow(RuntimeException("db down"))

        val controller = SystemController(
            jdbc = jdbc,
            metrics = LedgerMetrics(),
            consumerControl = mock(KafkaConsumerControl::class.java),
            kafkaEnabled = true,
            settlementConsumerEnabled = true,
            requireSettlementConsumer = true,
        )

        val response = controller.ready()
        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, response.statusCode)
        assertEquals("db_unready", response.body?.get("status"))
    }

    @Test
    fun readyReturnsConsumerUnavailableWhenSettlementListenerMissing() {
        val jdbc = mock(JdbcTemplate::class.java)
        val consumer = mock(KafkaConsumerControl::class.java)
        `when`(jdbc.queryForObject("SELECT 1", Int::class.java)).thenReturn(1)
        `when`(consumer.settlementStatus()).thenReturn(
            ConsumerControlStatus(
                available = false,
                listenerId = "ledger-settlement-consumer",
                running = false,
                pauseRequested = false,
                containerPaused = false,
                gatePaused = false,
            ),
        )

        val controller = SystemController(
            jdbc = jdbc,
            metrics = LedgerMetrics(),
            consumerControl = consumer,
            kafkaEnabled = true,
            settlementConsumerEnabled = true,
            requireSettlementConsumer = true,
        )

        val response = controller.ready()
        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, response.statusCode)
        assertEquals("settlement_consumer_unavailable", response.body?.get("status"))
    }

    @Test
    fun readyReturnsConsumerPausedWhenPauseGateIsOn() {
        val jdbc = mock(JdbcTemplate::class.java)
        val consumer = mock(KafkaConsumerControl::class.java)
        `when`(jdbc.queryForObject("SELECT 1", Int::class.java)).thenReturn(1)
        `when`(consumer.settlementStatus()).thenReturn(
            ConsumerControlStatus(
                available = true,
                listenerId = "ledger-settlement-consumer",
                running = true,
                pauseRequested = false,
                containerPaused = false,
                gatePaused = true,
            ),
        )

        val controller = SystemController(
            jdbc = jdbc,
            metrics = LedgerMetrics(),
            consumerControl = consumer,
            kafkaEnabled = true,
            settlementConsumerEnabled = true,
            requireSettlementConsumer = true,
        )

        val response = controller.ready()
        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, response.statusCode)
        assertEquals("settlement_consumer_paused", response.body?.get("status"))
    }

    @Test
    fun readyIgnoresConsumerStateWhenConsumerGateDisabled() {
        val jdbc = mock(JdbcTemplate::class.java)
        val consumer = mock(KafkaConsumerControl::class.java)
        `when`(jdbc.queryForObject("SELECT 1", Int::class.java)).thenReturn(1)
        `when`(consumer.settlementStatus()).thenReturn(
            ConsumerControlStatus(
                available = false,
                listenerId = "ledger-settlement-consumer",
                running = false,
                pauseRequested = true,
                containerPaused = true,
                gatePaused = true,
            ),
        )

        val controller = SystemController(
            jdbc = jdbc,
            metrics = LedgerMetrics(),
            consumerControl = consumer,
            kafkaEnabled = true,
            settlementConsumerEnabled = true,
            requireSettlementConsumer = false,
        )

        val response = controller.ready()
        assertEquals(HttpStatus.OK, response.statusCode)
        assertEquals("ready", response.body?.get("status"))
    }
}
