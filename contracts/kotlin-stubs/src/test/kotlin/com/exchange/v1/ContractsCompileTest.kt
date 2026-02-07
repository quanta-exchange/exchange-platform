package com.exchange.v1

import kotlin.test.Test
import kotlin.test.assertEquals

class ContractsCompileTest {
    @Test
    fun generatedContractTypesCompile() {
        val envelope = EventEnvelope.newBuilder()
            .setEventId("evt-1")
            .setEventVersion(1)
            .setSymbol("BTC-KRW")
            .setSeq(1)
            .setCorrelationId("corr-1")
            .setCausationId("cause-1")
            .build()

        assertEquals("BTC-KRW", envelope.symbol)
    }
}
