package com.quanta.exchange.streaming;

public final class CandleJob {
    private CandleJob() {}

    public static String health() {
        return "ok";
    }

    public static CandleAggregator candleAggregator() {
        return new CandleAggregator(60_000L);
    }

    public static Ticker24hAggregator ticker24hAggregator() {
        return new Ticker24hAggregator(24L * 60L * 60L * 1000L);
    }
}
