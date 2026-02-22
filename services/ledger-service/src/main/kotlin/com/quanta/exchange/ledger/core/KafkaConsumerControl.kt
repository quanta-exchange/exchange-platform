package com.quanta.exchange.ledger.core

import org.springframework.kafka.config.KafkaListenerEndpointRegistry
import org.springframework.stereotype.Component

data class ConsumerControlStatus(
    val available: Boolean,
    val listenerId: String,
    val running: Boolean,
    val pauseRequested: Boolean,
    val containerPaused: Boolean,
    val gatePaused: Boolean,
)

@Component
class KafkaConsumerControl(
    private val registry: KafkaListenerEndpointRegistry,
    private val settlementGate: SettlementConsumerGate,
) {
    private val settlementListenerId = "ledger-settlement-consumer"

    fun settlementStatus(): ConsumerControlStatus {
        val container = registry.getListenerContainer(settlementListenerId)
        if (container == null) {
            return ConsumerControlStatus(
                available = false,
                listenerId = settlementListenerId,
                running = false,
                pauseRequested = false,
                containerPaused = false,
                gatePaused = settlementGate.isPaused(),
            )
        }
        return ConsumerControlStatus(
            available = true,
            listenerId = settlementListenerId,
            running = container.isRunning,
            pauseRequested = container.isPauseRequested,
            containerPaused = resolveContainerPaused(container),
            gatePaused = settlementGate.isPaused(),
        )
    }

    fun pauseSettlement(): ConsumerControlStatus {
        val container = registry.getListenerContainer(settlementListenerId) ?: run {
            settlementGate.pause()
            return settlementStatus()
        }
        settlementGate.resume()
        container.pause()
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            val status = settlementStatus()
            if (status.containerPaused || !status.running) {
                return status
            }
            Thread.sleep(50)
        }
        return settlementStatus()
    }

    fun resumeSettlement(): ConsumerControlStatus {
        settlementGate.resume()
        val container = registry.getListenerContainer(settlementListenerId) ?: return settlementStatus()
        container.resume()
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            val status = settlementStatus()
            if (!status.containerPaused) {
                return status
            }
            Thread.sleep(50)
        }
        return settlementStatus()
    }

    private fun resolveContainerPaused(container: org.springframework.kafka.listener.MessageListenerContainer): Boolean {
        return try {
            val method = container.javaClass.getMethod("isContainerPaused")
            method.invoke(container) as? Boolean ?: container.isPauseRequested
        } catch (_: Exception) {
            container.isPauseRequested
        }
    }
}
