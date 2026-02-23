package com.quanta.exchange.ledger

import com.quanta.exchange.ledger.api.EventEnvelopeDto
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import java.time.Instant

class DtoValidationTest {
    @Test
    fun envelopeRejectsUnsupportedEventVersion() {
        val dto = EventEnvelopeDto(
            eventId = "evt-1",
            eventVersion = 2,
            symbol = "BTC-KRW",
            seq = 1,
            occurredAt = Instant.now(),
            correlationId = "corr-1",
            causationId = "cause-1",
        )

        val error = assertThrows(IllegalArgumentException::class.java) { dto.toModel() }
        assertEquals("unsupported_event_version", error.message)
    }

    @Test
    fun envelopeRejectsInvalidSymbol() {
        val dto = EventEnvelopeDto(
            eventId = "evt-2",
            eventVersion = 1,
            symbol = "bad_symbol",
            seq = 1,
            occurredAt = Instant.now(),
            correlationId = "corr-2",
            causationId = "cause-2",
        )

        val error = assertThrows(IllegalArgumentException::class.java) { dto.toModel() }
        assertEquals("invalid_symbol", error.message)
    }

    @Test
    fun envelopeNormalizesSymbolToUppercase() {
        val dto = EventEnvelopeDto(
            eventId = "evt-3",
            eventVersion = 1,
            symbol = "btc-krw",
            seq = 1,
            occurredAt = Instant.now(),
            correlationId = "corr-3",
            causationId = "cause-3",
        )

        val model = dto.toModel()
        assertEquals("BTC-KRW", model.symbol)
    }
}
