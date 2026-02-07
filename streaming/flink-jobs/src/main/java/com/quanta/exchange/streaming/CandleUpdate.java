package com.quanta.exchange.streaming;

public record CandleUpdate(
        String symbol,
        String interval,
        long openTimeMs,
        long closeTimeMs,
        long open,
        long high,
        long low,
        long close,
        long volume,
        long tradeCount,
        long seq,
        boolean isFinal
) {}
