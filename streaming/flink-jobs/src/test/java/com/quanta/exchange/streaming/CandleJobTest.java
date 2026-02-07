package com.quanta.exchange.streaming;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;

class CandleJobTest {
    @Test
    void healthIsOk() {
        assertEquals("ok", CandleJob.health());
    }

    @Test
    void emitsProgressAndFinalAtBoundary() {
        CandleAggregator aggregator = CandleJob.candleAggregator();
        long t0 = 1_700_000_000_000L;

        List<CandleUpdate> a = aggregator.onTrade(new TradeEvent("BTC-KRW", 1, t0, 100, 2));
        List<CandleUpdate> b = aggregator.onTrade(new TradeEvent("BTC-KRW", 2, t0 + 10_000, 110, 3));
        List<CandleUpdate> c = aggregator.onTrade(new TradeEvent("BTC-KRW", 3, t0 + 61_000, 120, 1));

        assertEquals(1, a.size());
        assertFalse(a.get(0).isFinal());
        assertEquals(100, a.get(0).open());
        assertEquals(2, a.get(0).volume());

        assertEquals(1, b.size());
        assertFalse(b.get(0).isFinal());
        assertEquals(110, b.get(0).close());
        assertEquals(110, b.get(0).high());
        assertEquals(5, b.get(0).volume());

        assertEquals(2, c.size());
        assertTrue(c.get(0).isFinal());
        assertEquals(5, c.get(0).volume());
        assertFalse(c.get(1).isFinal());
        assertEquals(120, c.get(1).open());
        assertEquals(120, c.get(1).close());
    }

    @Test
    void ignoresOutOfOrderBySeq() {
        CandleAggregator aggregator = CandleJob.candleAggregator();
        long t0 = 1_700_000_000_000L;

        List<CandleUpdate> first = aggregator.onTrade(new TradeEvent("ETH-KRW", 10, t0, 200, 1));
        List<CandleUpdate> stale = aggregator.onTrade(new TradeEvent("ETH-KRW", 9, t0 + 5_000, 210, 1));

        assertEquals(1, first.size());
        assertTrue(stale.isEmpty());
    }

    @Test
    void replayIsDeterministic() {
        List<TradeEvent> tape = List.of(
                new TradeEvent("SOL-KRW", 1, 1_700_000_000_000L, 10, 1),
                new TradeEvent("SOL-KRW", 2, 1_700_000_010_000L, 12, 1),
                new TradeEvent("SOL-KRW", 3, 1_700_000_061_000L, 11, 2));

        List<CandleUpdate> one = runTape(tape);
        List<CandleUpdate> two = runTape(tape);
        assertEquals(one, two);
    }

    private List<CandleUpdate> runTape(List<TradeEvent> tape) {
        CandleAggregator aggregator = CandleJob.candleAggregator();
        List<CandleUpdate> out = new ArrayList<>();
        for (TradeEvent trade : tape) {
            out.addAll(aggregator.onTrade(trade));
        }
        return out;
    }
}
