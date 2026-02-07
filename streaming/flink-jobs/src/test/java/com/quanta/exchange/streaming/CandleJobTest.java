package com.quanta.exchange.streaming;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class CandleJobTest {
    @Test
    void healthIsOk() {
        assertEquals("ok", CandleJob.health());
    }
}
