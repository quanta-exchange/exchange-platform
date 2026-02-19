package com.quanta.exchange.ledger.core

import org.springframework.stereotype.Component
import java.util.concurrent.atomic.AtomicBoolean

@Component
class SettlementConsumerGate {
    private val paused = AtomicBoolean(false)

    fun pause() {
        paused.set(true)
    }

    fun resume() {
        paused.set(false)
    }

    fun isPaused(): Boolean = paused.get()
}

