package com.quanta.exchange.ledger.api

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.quanta.exchange.ledger.core.BalanceAdjustmentCommand
import com.quanta.exchange.ledger.core.EventEnvelope
import com.quanta.exchange.ledger.core.ReserveCommand
import com.quanta.exchange.ledger.core.TradeExecuted
import java.time.Instant

@JsonIgnoreProperties(ignoreUnknown = true)
data class EventEnvelopeDto(
    val eventId: String,
    val eventVersion: Int = 1,
    val symbol: String,
    val seq: Long,
    val occurredAt: Instant,
    val correlationId: String,
    val causationId: String,
) {
    fun toModel(): EventEnvelope {
        return EventEnvelope(
            eventId = eventId,
            eventVersion = eventVersion,
            symbol = symbol,
            seq = seq,
            occurredAt = occurredAt,
            correlationId = correlationId,
            causationId = causationId,
        )
    }
}

@JsonIgnoreProperties(ignoreUnknown = true)
data class TradeExecutedDto(
    val envelope: EventEnvelopeDto,
    val tradeId: String,
    val buyerUserId: String,
    val sellerUserId: String,
    val price: Long,
    val quantity: Long,
    val quoteAmount: Long = 0,
    val feeBuyer: Long = 0,
    val feeSeller: Long = 0,
) {
    fun toModel(): TradeExecuted {
        return TradeExecuted(
            envelope = envelope.toModel(),
            tradeId = tradeId,
            buyerUserId = buyerUserId,
            sellerUserId = sellerUserId,
            price = price,
            quantity = quantity,
            quoteAmount = quoteAmount,
            feeBuyer = feeBuyer,
            feeSeller = feeSeller,
        )
    }
}

data class ReserveDto(
    val envelope: EventEnvelopeDto,
    val orderId: String,
    val userId: String,
    val side: String,
    val amount: Long,
) {
    fun toModel(): ReserveCommand {
        return ReserveCommand(
            envelope = envelope.toModel(),
            orderId = orderId,
            userId = userId,
            side = side,
            amount = amount,
        )
    }
}

data class EngineSeqDto(
    val symbol: String,
    val seq: Long,
)

data class BalanceAdjustmentDto(
    val envelope: EventEnvelopeDto,
    val referenceId: String,
    val userId: String,
    val currency: String,
    val amountDelta: Long,
) {
    fun toModel(): BalanceAdjustmentCommand {
        return BalanceAdjustmentCommand(
            envelope = envelope.toModel(),
            referenceId = referenceId,
            userId = userId,
            currency = currency,
            amountDelta = amountDelta,
        )
    }
}

data class CreateCorrectionDto(
    val correctionId: String,
    val originalEntryId: String,
    val mode: String,
    val reason: String,
    val ticketId: String,
    val requestedBy: String,
)

data class ApproveCorrectionDto(
    val approver: String,
)

data class ApplyCorrectionDto(
    val envelope: EventEnvelopeDto,
)
