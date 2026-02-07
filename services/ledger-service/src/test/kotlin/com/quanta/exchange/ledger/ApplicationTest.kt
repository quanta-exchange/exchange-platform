package com.quanta.exchange.ledger

import kotlin.test.Test
import kotlin.test.assertEquals

class ApplicationTest {
    @Test
    fun healthIsOk() {
        val res = health()
        assertEquals("ledger-service", res.service)
        assertEquals("ok", res.status)
    }
}
