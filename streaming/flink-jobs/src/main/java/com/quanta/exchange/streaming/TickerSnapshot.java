package com.quanta.exchange.streaming;

public record TickerSnapshot(
        String symbol,
        long seq,
        long windowStartMs,
        long windowEndMs,
        long lastPrice,
        long high24h,
        long low24h,
        long volume24h,
        long quoteVolume24h
) {}
