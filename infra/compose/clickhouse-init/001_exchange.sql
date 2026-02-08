CREATE DATABASE IF NOT EXISTS exchange;

CREATE TABLE IF NOT EXISTS exchange.trades (
    symbol LowCardinality(String),
    seq UInt64,
    event_time DateTime64(3, 'UTC'),
    trade_id String,
    price Int64,
    quantity Int64,
    quote_amount Int64,
    buyer_user_id String,
    seller_user_id String
)
ENGINE = MergeTree
PARTITION BY toDate(event_time)
ORDER BY (symbol, event_time, seq)
TTL event_time + INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS exchange.candles (
    symbol LowCardinality(String),
    interval LowCardinality(String),
    open_time DateTime64(3, 'UTC'),
    close_time DateTime64(3, 'UTC'),
    open Int64,
    high Int64,
    low Int64,
    close Int64,
    volume Int64,
    trade_count UInt64,
    is_final UInt8,
    seq UInt64
)
ENGINE = ReplacingMergeTree(seq)
PARTITION BY toDate(open_time)
ORDER BY (symbol, interval, open_time)
TTL open_time + INTERVAL 365 DAY;
