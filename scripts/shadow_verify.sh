#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/shadow}"
TRADE_FILE="${TRADE_FILE:-}"
BALANCE_FILE="${BALANCE_FILE:-}"
WINDOW_MINUTES="${WINDOW_MINUTES:-10}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
USE_SAMPLE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --trade-file)
      TRADE_FILE="$2"
      USE_SAMPLE=false
      shift 2
      ;;
    --balance-file)
      BALANCE_FILE="$2"
      shift 2
      ;;
    --window-minutes)
      WINDOW_MINUTES="$2"
      shift 2
      ;;
    --sample)
      USE_SAMPLE=true
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! [[ "$WINDOW_MINUTES" =~ ^[0-9]+$ ]] || [[ "$WINDOW_MINUTES" -lt 1 ]]; then
  echo "WINDOW_MINUTES must be a positive integer" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TS_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
REPORT_FILE="$OUT_DIR/shadow-verify-$TS_ID.json"
LATEST_FILE="$OUT_DIR/shadow-verify-latest.json"

"$PYTHON_BIN" - "$REPORT_FILE" "$TRADE_FILE" "$BALANCE_FILE" "$WINDOW_MINUTES" "$USE_SAMPLE" <<'PY'
import hashlib
import json
import random
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

report_file = Path(sys.argv[1]).resolve()
trade_file = Path(sys.argv[2]).resolve() if sys.argv[2] else None
balance_file = Path(sys.argv[3]).resolve() if sys.argv[3] else None
window_minutes = int(sys.argv[4])
use_sample = sys.argv[5].lower() == "true"


@dataclass(frozen=True)
class Trade:
    trade_id: str
    symbol: str
    ts_ms: int
    price: Decimal
    qty: Decimal


def parse_trade_line(line: str) -> Trade | None:
    try:
        payload = json.loads(line)
    except json.JSONDecodeError:
        return None

    trade_id = payload.get("tradeId") or payload.get("trade_id")
    symbol = payload.get("symbol")
    ts = payload.get("ts") or payload.get("timestamp")
    price = payload.get("price")
    qty = payload.get("quantity") or payload.get("qty")

    if not trade_id or not symbol or ts is None or price is None or qty is None:
        return None

    try:
        ts_ms = int(ts)
        return Trade(
            trade_id=str(trade_id),
            symbol=str(symbol),
            ts_ms=ts_ms,
            price=Decimal(str(price)),
            qty=Decimal(str(qty)),
        )
    except Exception:
        return None


def load_trade_events(path: Path, window_min: int):
    if not path.exists():
        raise FileNotFoundError(f"trade file not found: {path}")

    now_ms = int(datetime.now(timezone.utc).timestamp() * 1000)
    window_start = now_ms - (window_min * 60 * 1000)
    trades = []
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            t = parse_trade_line(raw.strip())
            if not t:
                continue
            if t.ts_ms < window_start:
                continue
            trades.append(t)
    return trades


def sample_trade_events(window_min: int):
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    window_start = now - timedelta(minutes=window_min)
    rng = random.Random(42)
    symbols = ["BTC-KRW", "ETH-KRW"]
    trades = []
    idx = 0
    for minute in range(window_min):
        base_ts = int((window_start + timedelta(minutes=minute)).timestamp() * 1000)
        for symbol in symbols:
            for step in range(2):
                idx += 1
                ts_ms = base_ts + (step * 15000)
                drift = Decimal(str(rng.randint(-20, 20)))
                base = Decimal("100000000") if symbol.startswith("BTC") else Decimal("5000000")
                price = base + drift
                qty = Decimal("0.01") if symbol.startswith("BTC") else Decimal("0.2")
                trades.append(
                    Trade(
                        trade_id=f"sample-{symbol}-{idx}",
                        symbol=symbol,
                        ts_ms=ts_ms,
                        price=price,
                        qty=qty,
                    )
                )
    return trades


def build_candles(trades):
    candles = {}
    ordered = sorted(trades, key=lambda t: (t.symbol, t.ts_ms, t.trade_id))
    for trade in ordered:
        bucket = (trade.ts_ms // 60000) * 60000
        key = (trade.symbol, bucket)
        c = candles.get(key)
        if c is None:
            candles[key] = {
                "symbol": trade.symbol,
                "bucket_ts_ms": bucket,
                "open": str(trade.price),
                "high": str(trade.price),
                "low": str(trade.price),
                "close": str(trade.price),
                "volume": str(trade.qty),
                "trades": 1,
            }
            continue

        high = max(Decimal(c["high"]), trade.price)
        low = min(Decimal(c["low"]), trade.price)
        volume = Decimal(c["volume"]) + trade.qty
        c["high"] = str(high)
        c["low"] = str(low)
        c["close"] = str(trade.price)
        c["volume"] = str(volume)
        c["trades"] += 1

    return {f"{k[0]}:{k[1]}": v for k, v in candles.items()}


def candle_diff(a: dict, b: dict):
    diffs = []
    keys = sorted(set(a.keys()) | set(b.keys()))
    for key in keys:
        if a.get(key) != b.get(key):
            diffs.append(
                {
                    "key": key,
                    "left": a.get(key),
                    "right": b.get(key),
                }
            )
    return diffs


def sample_balances():
    return [
        {"accountId": "alice", "asset": "KRW", "available": "1000000", "hold": "0", "total": "1000000"},
        {"accountId": "alice", "asset": "BTC", "available": "1.25", "hold": "0.10", "total": "1.35"},
        {"accountId": "bob", "asset": "ETH", "available": "8.0", "hold": "0", "total": "8.0"},
    ]


def load_balances(path: Path):
    if not path.exists():
        raise FileNotFoundError(f"balance file not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        payload = json.load(f)
    if isinstance(payload, dict):
        balances = payload.get("balances") or payload.get("rows") or []
    elif isinstance(payload, list):
        balances = payload
    else:
        balances = []
    return balances


def balances_hash(rows):
    normalized = []
    for row in rows:
        normalized.append(
            {
                "accountId": str(row.get("accountId") or row.get("account_id") or ""),
                "asset": str(row.get("asset") or row.get("currency") or ""),
                "available": str(row.get("available", "0")),
                "hold": str(row.get("hold", "0")),
                "total": str(row.get("total", "0")),
            }
        )
    normalized.sort(key=lambda r: (r["accountId"], r["asset"]))
    payload = json.dumps(normalized, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


if use_sample or trade_file is None:
    trades = sample_trade_events(window_minutes)
    trade_source = "sample"
else:
    trades = load_trade_events(trade_file, window_minutes)
    trade_source = str(trade_file)

if balance_file is None:
    balances = sample_balances()
    balance_source = "sample"
else:
    balances = load_balances(balance_file)
    balance_source = str(balance_file)

candles_a = build_candles(trades)
candles_b = build_candles(list(reversed(trades)))
diffs = candle_diff(candles_a, candles_b)

hash_a = balances_hash(balances)
hash_b = balances_hash(list(reversed(balances)))

ok = len(diffs) == 0 and hash_a == hash_b

report = {
    "generated_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ok": ok,
    "inputs": {
        "trade_source": trade_source,
        "balance_source": balance_source,
        "window_minutes": window_minutes,
        "trade_count": len(trades),
        "balance_rows": len(balances),
    },
    "candle_check": {
        "candle_count": len(candles_a),
        "diff_count": len(diffs),
        "diff_examples": diffs[:5],
    },
    "balance_check": {
        "hash_a": hash_a,
        "hash_b": hash_b,
        "hash_match": hash_a == hash_b,
    },
}

report_file.parent.mkdir(parents=True, exist_ok=True)
with report_file.open("w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=True)
    f.write("\n")

if not ok:
    sys.exit(1)
PY

cp "$REPORT_FILE" "$LATEST_FILE"

echo "shadow_verify_report=$REPORT_FILE"
echo "shadow_verify_latest=$LATEST_FILE"
echo "shadow_verify_ok=true"
