package com.quanta.exchange.streaming;

public record TradeEvent(
        String symbol,
        long seq,
        long eventTimeMs,
        long price,
        long quantity
) {}
