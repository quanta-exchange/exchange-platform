package com.quanta.exchange.streaming;

import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Rolling 24h ticker aggregator with seq-based de-dup.
 */
public final class Ticker24hAggregator {
    private final long windowMs;
    private final Map<String, SymbolWindow> windows = new HashMap<>();

    public Ticker24hAggregator(long windowMs) {
        this.windowMs = windowMs;
    }

    public Optional<TickerSnapshot> onTrade(TradeEvent trade) {
        if (trade.price() <= 0 || trade.quantity() <= 0) {
            return Optional.empty();
        }
        SymbolWindow window = windows.computeIfAbsent(trade.symbol(), ignored -> new SymbolWindow());
        if (trade.seq() <= window.lastSeq) {
            return Optional.empty();
        }

        window.lastSeq = trade.seq();
        window.trades.addLast(trade);
        evictOld(window, trade.eventTimeMs());

        long high = Long.MIN_VALUE;
        long low = Long.MAX_VALUE;
        long volume = 0L;
        long quoteVolume = 0L;
        long start = trade.eventTimeMs();
        for (TradeEvent event : window.trades) {
            high = Math.max(high, event.price());
            low = Math.min(low, event.price());
            volume = Math.addExact(volume, event.quantity());
            quoteVolume = Math.addExact(quoteVolume, Math.multiplyExact(event.price(), event.quantity()));
            start = Math.min(start, event.eventTimeMs());
        }

        return Optional.of(new TickerSnapshot(
                trade.symbol(),
                trade.seq(),
                start,
                trade.eventTimeMs(),
                trade.price(),
                high,
                low,
                volume,
                quoteVolume));
    }

    private void evictOld(SymbolWindow window, long nowMs) {
        long threshold = nowMs - windowMs;
        while (!window.trades.isEmpty() && window.trades.peekFirst().eventTimeMs() < threshold) {
            window.trades.removeFirst();
        }
    }

    private static final class SymbolWindow {
        private long lastSeq = -1;
        private final Deque<TradeEvent> trades = new ArrayDeque<>();
    }
}
