#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/candles}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SEED="${SEED:-424242}"
SYMBOLS="${SYMBOLS:-BTC-KRW,ETH-KRW}"
TRADES_PER_SYMBOL="${TRADES_PER_SYMBOL:-300}"
INTERVAL_SEC="${INTERVAL_SEC:-60}"

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/prove-candles-$TS_ID.json"
LATEST_FILE="$OUT_DIR/prove-candles-latest.json"

"$PYTHON_BIN" - "$REPORT_FILE" "$SEED" "$SYMBOLS" "$TRADES_PER_SYMBOL" "$INTERVAL_SEC" <<'PY'
import json
import random
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal

report_file = sys.argv[1]
seed = int(sys.argv[2])
symbols = [s.strip() for s in sys.argv[3].split(",") if s.strip()]
trades_per_symbol = int(sys.argv[4])
interval_sec = int(sys.argv[5])

if not symbols:
    raise SystemExit("symbols must not be empty")
if trades_per_symbol < 10:
    raise SystemExit("trades_per_symbol must be >= 10")
if interval_sec <= 0:
    raise SystemExit("interval_sec must be > 0")

rng = random.Random(seed)
interval_ms = interval_sec * 1000


def bucket_ts(ts_ms: int) -> int:
    return (ts_ms // interval_ms) * interval_ms


def make_trade(symbol: str, idx: int, base_ts: int):
    price_base = Decimal("100000000") if symbol.startswith("BTC") else Decimal("5000000")
    price = price_base + Decimal(str(rng.randint(-300, 300)))
    qty = Decimal("0.01") if symbol.startswith("BTC") else Decimal("0.2")
    ts_offset_ms = rng.randint(0, 9 * interval_ms)
    ts_ms = base_ts + ts_offset_ms
    return {
        "trade_id": f"t-{symbol}-{idx}",
        "symbol": symbol,
        "ts_ms": ts_ms,
        "price": price,
        "qty": qty,
    }


def update_candle(store, trade):
    key = f"{trade['symbol']}:{bucket_ts(trade['ts_ms'])}"
    current = store.get(key)
    if current is None:
        store[key] = {
            "symbol": trade["symbol"],
            "bucket_ts_ms": bucket_ts(trade["ts_ms"]),
            "open": str(trade["price"]),
            "open_ts_ms": trade["ts_ms"],
            "open_trade_id": trade["trade_id"],
            "high": str(trade["price"]),
            "low": str(trade["price"]),
            "close": str(trade["price"]),
            "close_ts_ms": trade["ts_ms"],
            "close_trade_id": trade["trade_id"],
            "volume": str(trade["qty"]),
            "trade_count": 1,
        }
        return

    price = trade["price"]
    qty = trade["qty"]
    high = max(Decimal(current["high"]), price)
    low = min(Decimal(current["low"]), price)
    volume = Decimal(current["volume"]) + qty
    current["high"] = str(high)
    current["low"] = str(low)
    current["volume"] = str(volume)
    current["trade_count"] += 1

    if (trade["ts_ms"] < current["open_ts_ms"]) or (
        trade["ts_ms"] == current["open_ts_ms"] and trade["trade_id"] < current["open_trade_id"]
    ):
        current["open"] = str(price)
        current["open_ts_ms"] = trade["ts_ms"]
        current["open_trade_id"] = trade["trade_id"]

    if (trade["ts_ms"] > current["close_ts_ms"]) or (
        trade["ts_ms"] == current["close_ts_ms"] and trade["trade_id"] > current["close_trade_id"]
    ):
        current["close"] = str(price)
        current["close_ts_ms"] = trade["ts_ms"]
        current["close_trade_id"] = trade["trade_id"]


def normalize(store):
    out = {}
    for key, row in store.items():
        out[key] = {
            "symbol": row["symbol"],
            "bucket_ts_ms": row["bucket_ts_ms"],
            "open": row["open"],
            "high": row["high"],
            "low": row["low"],
            "close": row["close"],
            "volume": row["volume"],
            "trade_count": row["trade_count"],
        }
    return out


def diff(left, right):
    keys = sorted(set(left.keys()) | set(right.keys()))
    out = []
    for key in keys:
        if left.get(key) != right.get(key):
            out.append({"key": key, "left": left.get(key), "right": right.get(key)})
    return out


now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
base_ts = int((now - timedelta(minutes=30)).timestamp() * 1000)

canonical_trades = []
for symbol in symbols:
    for idx in range(trades_per_symbol):
        canonical_trades.append(make_trade(symbol, idx + 1, base_ts))

# Inject duplicates to emulate at-least-once transport.
duplicate_count = max(1, len(canonical_trades) // 10)
duplicate_samples = rng.sample(canonical_trades, duplicate_count)
stream = canonical_trades + [dict(item) for item in duplicate_samples]
rng.shuffle(stream)

seen = set()
online = {}
for trade in stream:
    if trade["trade_id"] in seen:
        continue
    seen.add(trade["trade_id"])
    update_candle(online, trade)

canonical_sorted = sorted(
    canonical_trades,
    key=lambda t: (t["symbol"], bucket_ts(t["ts_ms"]), t["ts_ms"], t["trade_id"]),
)
rebuild = {}
for trade in canonical_sorted:
    update_candle(rebuild, trade)

online_norm = normalize(online)
rebuild_norm = normalize(rebuild)
diffs = diff(online_norm, rebuild_norm)

ok = len(diffs) == 0 and len(seen) == len(canonical_trades)

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "seed": seed,
    "symbols": symbols,
    "interval_sec": interval_sec,
    "inputs": {
        "canonical_trade_count": len(canonical_trades),
        "duplicate_injected_count": duplicate_count,
        "stream_trade_count": len(stream),
    },
    "checks": {
        "dedupe_unique_count": len(seen),
        "rebuild_candle_count": len(rebuild_norm),
        "online_candle_count": len(online_norm),
        "diff_count": len(diffs),
        "diff_examples": diffs[:5],
    },
}

with open(report_file, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")

if not ok:
    raise SystemExit(1)
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "prove_candles_report=${REPORT_FILE}"
echo "prove_candles_latest=${LATEST_FILE}"
echo "prove_candles_ok=true"
