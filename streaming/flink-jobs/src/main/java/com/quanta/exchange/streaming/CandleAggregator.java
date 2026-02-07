package com.quanta.exchange.streaming;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Deterministic 1m candle aggregator.
 * Out-of-order events are resolved by engine seq preference:
 * seq <= lastSeq for a symbol is ignored.
 */
public final class CandleAggregator {
    private final long intervalMs;
    private final Map<String, SymbolState> states = new HashMap<>();

    public CandleAggregator(long intervalMs) {
        this.intervalMs = intervalMs;
    }

    public List<CandleUpdate> onTrade(TradeEvent trade) {
        if (trade.price() <= 0 || trade.quantity() <= 0) {
            return List.of();
        }

        SymbolState state = states.computeIfAbsent(trade.symbol(), ignored -> new SymbolState());
        if (trade.seq() <= state.lastSeq) {
            return List.of();
        }
        state.lastSeq = trade.seq();

        long bucketStart = bucketStart(trade.eventTimeMs());
        long bucketEnd = bucketStart + intervalMs - 1;

        List<CandleUpdate> updates = new ArrayList<>();
        if (state.current == null) {
            state.current = MutableCandle.fromTrade(trade, bucketStart, bucketEnd);
            updates.add(state.current.snapshot(false));
            return updates;
        }

        if (bucketStart == state.current.openTimeMs) {
            state.current.applyTrade(trade);
            updates.add(state.current.snapshot(false));
            return updates;
        }

        if (bucketStart > state.current.openTimeMs) {
            updates.add(state.current.snapshot(true));
            state.current = MutableCandle.fromTrade(trade, bucketStart, bucketEnd);
            updates.add(state.current.snapshot(false));
            return updates;
        }

        return updates;
    }

    public Optional<CandleUpdate> flushFinal(String symbol) {
        SymbolState state = states.get(symbol);
        if (state == null || state.current == null) {
            return Optional.empty();
        }
        CandleUpdate finalCandle = state.current.snapshot(true);
        state.current = null;
        return Optional.of(finalCandle);
    }

    private long bucketStart(long tsMs) {
        return (tsMs / intervalMs) * intervalMs;
    }

    private static final class SymbolState {
        private long lastSeq = -1;
        private MutableCandle current;
    }

    private static final class MutableCandle {
        private final String symbol;
        private final String interval;
        private final long openTimeMs;
        private final long closeTimeMs;
        private final long open;
        private long high;
        private long low;
        private long close;
        private long volume;
        private long tradeCount;
        private long seq;

        private MutableCandle(
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
                long seq) {
            this.symbol = symbol;
            this.interval = interval;
            this.openTimeMs = openTimeMs;
            this.closeTimeMs = closeTimeMs;
            this.open = open;
            this.high = high;
            this.low = low;
            this.close = close;
            this.volume = volume;
            this.tradeCount = tradeCount;
            this.seq = seq;
        }

        static MutableCandle fromTrade(TradeEvent trade, long openTimeMs, long closeTimeMs) {
            return new MutableCandle(
                    trade.symbol(),
                    "1m",
                    openTimeMs,
                    closeTimeMs,
                    trade.price(),
                    trade.price(),
                    trade.price(),
                    trade.price(),
                    trade.quantity(),
                    1,
                    trade.seq());
        }

        void applyTrade(TradeEvent trade) {
            high = Math.max(high, trade.price());
            low = Math.min(low, trade.price());
            close = trade.price();
            volume = Math.addExact(volume, trade.quantity());
            tradeCount = Math.addExact(tradeCount, 1);
            seq = trade.seq();
        }

        CandleUpdate snapshot(boolean isFinal) {
            return new CandleUpdate(
                    symbol,
                    interval,
                    openTimeMs,
                    closeTimeMs,
                    open,
                    high,
                    low,
                    close,
                    volume,
                    tradeCount,
                    seq,
                    isFinal);
        }
    }
}
