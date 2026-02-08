package com.quanta.exchange.streaming;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Optional;
import org.junit.jupiter.api.Test;

class Ticker24hAggregatorTest {
    @Test
    void computesRolling24hTicker() {
        Ticker24hAggregator aggregator = CandleJob.ticker24hAggregator();
        long base = 1_700_000_000_000L;

        TickerSnapshot t1 = aggregator.onTrade(new TradeEvent("BTC-KRW", 1, base, 100, 2)).orElseThrow();
        TickerSnapshot t2 = aggregator.onTrade(new TradeEvent("BTC-KRW", 2, base + 1000, 120, 1)).orElseThrow();
        TickerSnapshot t3 = aggregator.onTrade(new TradeEvent("BTC-KRW", 3, base + 2000, 90, 4)).orElseThrow();

        assertEquals(100, t1.lastPrice());
        assertEquals(120, t2.high24h());
        assertEquals(90, t3.low24h());
        assertEquals(7, t3.volume24h());
        assertEquals(680, t3.quoteVolume24h());
    }

    @Test
    void evictsOlderThan24hWindow() {
        Ticker24hAggregator aggregator = CandleJob.ticker24hAggregator();
        long base = 1_700_000_000_000L;
        long dayMs = 24L * 60L * 60L * 1000L;

        aggregator.onTrade(new TradeEvent("ETH-KRW", 1, base, 10, 1)).orElseThrow();
        TickerSnapshot current = aggregator.onTrade(new TradeEvent("ETH-KRW", 2, base + dayMs + 1, 20, 3)).orElseThrow();

        assertEquals(3, current.volume24h());
        assertEquals(20, current.high24h());
        assertEquals(20, current.low24h());
    }

    @Test
    void ignoresStaleSeq() {
        Ticker24hAggregator aggregator = CandleJob.ticker24hAggregator();
        long base = 1_700_000_000_000L;

        Optional<TickerSnapshot> first = aggregator.onTrade(new TradeEvent("XRP-KRW", 5, base, 1, 10));
        Optional<TickerSnapshot> stale = aggregator.onTrade(new TradeEvent("XRP-KRW", 4, base + 100, 2, 1));

        assertTrue(first.isPresent());
        assertFalse(stale.isPresent());
    }
}
