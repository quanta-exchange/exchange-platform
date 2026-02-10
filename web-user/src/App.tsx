import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  cancelOrder,
  createOrder,
  fetchCandles,
  fetchOrder,
  fetchOrderbook,
  fetchTicker,
  fetchTrades,
  getWsUrl,
  postSmokeTrade,
} from "./lib/api";
import {
  asNumber,
  formatCompact,
  formatCount,
  formatPrice,
  formatQty,
  formatSignedPercent,
} from "./lib/format";
import type {
  OrderRequest,
  OrderResponse,
  OrderbookResponse,
  RawTickerData,
  WsMessage,
} from "./types";

const WATCH_SYMBOLS = ["BTC-KRW", "ETH-KRW", "SOL-KRW", "XRP-KRW", "BNB-KRW"];
const NAV_ITEMS = ["Buy Crypto", "Markets", "Trade", "Futures", "Earn", "Square"];
const NEWS_HEADLINES = [
  "Engine WAL durability path is now wired to Web User feed.",
  "Ledger reconciliation guard remains append-only by policy.",
  "Candle stream now supports gap resume from last seen seq.",
  "Edge gateway replay defense keeps duplicate signatures out.",
];

type ConnectionState = "connecting" | "open" | "closed";

type TickerView = {
  symbol: string;
  lastPrice: number;
  high24h: number;
  low24h: number;
  volume24h: number;
  quoteVolume24h: number;
  seq: number;
  ts: number;
};

type TradeView = {
  tradeId: string;
  price: number;
  qty: number;
  seq: number;
  ts: number;
};

type CandleView = {
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
  tradeCount: number;
  isFinal: boolean;
  interval: string;
  seq: number;
  ts: number;
};

type BookLevelView = {
  price: number;
  qty: number;
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim() !== "") {
    return error.message;
  }
  return "unknown error";
}

function toTickerFromMessage(
  symbol: string,
  payload: Partial<WsMessage<RawTickerData>> | Record<string, never>,
): TickerView | null {
  if (!isObject(payload)) {
    return null;
  }
  const data = payload.data;
  if (!isObject(data)) {
    return null;
  }

  const lastPrice = asNumber(data.lastPrice);
  if (lastPrice <= 0) {
    return null;
  }

  return {
    symbol,
    lastPrice,
    high24h: asNumber(data.high24h),
    low24h: asNumber(data.low24h),
    volume24h: asNumber(data.volume24h),
    quoteVolume24h: asNumber(data.quoteVolume24h),
    seq: Math.trunc(asNumber(payload.seq)),
    ts: Math.trunc(asNumber(payload.ts)) || Date.now(),
  };
}

function toTradeFromMessage(message: WsMessage<Record<string, unknown>>): TradeView | null {
  if (!isObject(message.data)) {
    return null;
  }
  const price = asNumber(message.data.price);
  const qty = asNumber(message.data.qty);
  if (price <= 0 || qty <= 0) {
    return null;
  }

  const rawTradeId = message.data.tradeId;
  const tradeId = typeof rawTradeId === "string" ? rawTradeId : `seq-${message.seq}`;
  return {
    tradeId,
    price,
    qty,
    seq: Math.trunc(asNumber(message.seq)),
    ts: Math.trunc(asNumber(message.ts)) || Date.now(),
  };
}

function toCandleFromMessage(message: WsMessage<Record<string, unknown>>): CandleView | null {
  if (!isObject(message.data)) {
    return null;
  }
  const open = asNumber(message.data.open);
  const high = asNumber(message.data.high);
  const low = asNumber(message.data.low);
  const close = asNumber(message.data.close);
  const volume = asNumber(message.data.volume);

  if (open <= 0 || close <= 0) {
    return null;
  }

  return {
    open,
    high,
    low,
    close,
    volume,
    tradeCount: Math.trunc(asNumber(message.data.tradeCount)),
    isFinal: Boolean(message.data.isFinal),
    interval: typeof message.data.interval === "string" ? message.data.interval : "1m",
    seq: Math.trunc(asNumber(message.seq)),
    ts: Math.trunc(asNumber(message.ts)) || Date.now(),
  };
}

function upsertTickerRow(rows: TickerView[], nextRow: TickerView): TickerView[] {
  const hasRow = rows.some((row) => row.symbol === nextRow.symbol);
  const merged = hasRow
    ? rows.map((row) => (row.symbol === nextRow.symbol ? nextRow : row))
    : [...rows, nextRow];

  return merged.sort((a, b) => WATCH_SYMBOLS.indexOf(a.symbol) - WATCH_SYMBOLS.indexOf(b.symbol));
}

function normalizeBookLevels(levels: unknown[]): BookLevelView[] {
  return levels
    .map((level) => {
      if (Array.isArray(level)) {
        return {
          price: asNumber(level[0]),
          qty: asNumber(level[1]),
        };
      }
      if (isObject(level)) {
        return {
          price: asNumber(level.price),
          qty: asNumber(level.qty),
        };
      }
      return { price: 0, qty: 0 };
    })
    .filter((level) => level.price > 0 && level.qty > 0)
    .slice(0, 10);
}

export default function App() {
  const [selectedSymbol, setSelectedSymbol] = useState<string>(WATCH_SYMBOLS[0]);
  const [marketRows, setMarketRows] = useState<TickerView[]>([]);
  const [ticker, setTicker] = useState<TickerView | null>(null);
  const [trades, setTrades] = useState<TradeView[]>([]);
  const [candle, setCandle] = useState<CandleView | null>(null);
  const [orderbook, setOrderbook] = useState<OrderbookResponse | null>(null);

  const [connectionState, setConnectionState] = useState<ConnectionState>("connecting");
  const [loadingSymbol, setLoadingSymbol] = useState<boolean>(false);
  const [panelError, setPanelError] = useState<string>("");
  const [actionMessage, setActionMessage] = useState<string>("");

  const [isSubmittingOrder, setIsSubmittingOrder] = useState<boolean>(false);
  const [isSeedingTrade, setIsSeedingTrade] = useState<boolean>(false);
  const [lastOrder, setLastOrder] = useState<OrderResponse | null>(null);
  const [orderForm, setOrderForm] = useState<OrderRequest>({
    symbol: WATCH_SYMBOLS[0],
    side: "BUY",
    type: "LIMIT",
    price: "100000000",
    qty: "10000",
    timeInForce: "GTC",
  });

  const wsSeqRef = useRef<number>(0);

  const selectedTicker = useMemo(() => {
    return ticker ?? marketRows.find((row) => row.symbol === selectedSymbol) ?? null;
  }, [marketRows, selectedSymbol, ticker]);

  const bandPercent = useMemo(() => {
    if (!selectedTicker || selectedTicker.low24h <= 0) {
      return 0;
    }
    return ((selectedTicker.high24h - selectedTicker.low24h) / selectedTicker.low24h) * 100;
  }, [selectedTicker]);

  const heroUsers = useMemo(() => {
    const fromVolume = Math.round((selectedTicker?.quoteVolume24h ?? 0) / 1_500);
    return Math.max(30720133, fromVolume);
  }, [selectedTicker]);

  const orderbookBids = useMemo(() => normalizeBookLevels(orderbook?.bids ?? []), [orderbook]);
  const orderbookAsks = useMemo(() => normalizeBookLevels(orderbook?.asks ?? []), [orderbook]);

  const refreshWatchBoard = useCallback(async () => {
    const responses = await Promise.all(
      WATCH_SYMBOLS.map(async (symbol) => {
        try {
          const tickerResponse = await fetchTicker(symbol);
          return toTickerFromMessage(symbol, tickerResponse.ticker);
        } catch {
          return null;
        }
      }),
    );

    const validRows = responses.filter((row): row is TickerView => row !== null);
    if (validRows.length > 0) {
      validRows.sort((a, b) => WATCH_SYMBOLS.indexOf(a.symbol) - WATCH_SYMBOLS.indexOf(b.symbol));
      setMarketRows(validRows);
    }
  }, []);

  const loadSymbolData = useCallback(async (symbol: string) => {
    setLoadingSymbol(true);
    setPanelError("");
    try {
      const [tickerResponse, tradesResponse, candlesResponse, orderbookResponse] = await Promise.all([
        fetchTicker(symbol),
        fetchTrades(symbol, 30),
        fetchCandles(symbol),
        fetchOrderbook(symbol, 20),
      ]);

      const tickerRow = toTickerFromMessage(symbol, tickerResponse.ticker);
      setTicker(tickerRow);
      if (tickerRow) {
        setMarketRows((prev) => upsertTickerRow(prev, tickerRow));
      }

      const tradeRows = tradesResponse.trades
        .map((msg) => toTradeFromMessage(msg))
        .filter((row): row is TradeView => row !== null)
        .slice(-30)
        .reverse();
      setTrades(tradeRows);

      const latestCandle =
        candlesResponse.candles
          .map((msg) => toCandleFromMessage(msg))
          .filter((row): row is CandleView => row !== null)
          .at(-1) ?? null;
      setCandle(latestCandle);

      setOrderbook(orderbookResponse);
    } catch (error) {
      setPanelError(`시세 로드 실패 · ${toErrorMessage(error)}`);
    } finally {
      setLoadingSymbol(false);
    }
  }, []);

  useEffect(() => {
    void refreshWatchBoard();
    const timer = window.setInterval(() => {
      void refreshWatchBoard();
    }, 8000);
    return () => window.clearInterval(timer);
  }, [refreshWatchBoard]);

  useEffect(() => {
    wsSeqRef.current = 0;
    setOrderForm((prev) => ({ ...prev, symbol: selectedSymbol }));
    void loadSymbolData(selectedSymbol);
  }, [loadSymbolData, selectedSymbol]);

  useEffect(() => {
    let socket: WebSocket | null = null;
    let reconnectTimer: number | undefined;
    let disposed = false;

    const connect = () => {
      if (disposed) {
        return;
      }

      setConnectionState("connecting");
      socket = new WebSocket(getWsUrl());

      socket.onopen = () => {
        if (!socket || socket.readyState !== WebSocket.OPEN) {
          return;
        }
        setConnectionState("open");

        socket.send(JSON.stringify({ op: "SUB", channel: "trades", symbol: selectedSymbol }));
        socket.send(JSON.stringify({ op: "SUB", channel: "ticker", symbol: selectedSymbol }));
        socket.send(JSON.stringify({ op: "SUB", channel: "candles", symbol: selectedSymbol }));

        if (wsSeqRef.current > 0) {
          socket.send(
            JSON.stringify({
              op: "RESUME",
              symbol: selectedSymbol,
              lastSeq: wsSeqRef.current,
            }),
          );
        }
      };

      socket.onmessage = (event: MessageEvent<string>) => {
        let message: WsMessage<Record<string, unknown>>;
        try {
          message = JSON.parse(event.data) as WsMessage<Record<string, unknown>>;
        } catch {
          return;
        }

        const currentSeq = Math.trunc(asNumber(message.seq));
        if (currentSeq > wsSeqRef.current) {
          wsSeqRef.current = currentSeq;
        }

        if (message.symbol !== selectedSymbol) {
          return;
        }

        if (message.channel === "ticker") {
          const nextTicker = toTickerFromMessage(
            selectedSymbol,
            message as Partial<WsMessage<RawTickerData>>,
          );
          if (nextTicker) {
            setTicker(nextTicker);
            setMarketRows((prev) => upsertTickerRow(prev, nextTicker));
          }
          return;
        }

        if (message.channel === "trades") {
          const nextTrade = toTradeFromMessage(message);
          if (nextTrade) {
            setTrades((prev) => [nextTrade, ...prev].slice(0, 30));
          }
          return;
        }

        if (message.channel === "candles") {
          const nextCandle = toCandleFromMessage(message);
          if (nextCandle) {
            setCandle(nextCandle);
          }
        }
      };

      socket.onclose = () => {
        if (disposed) {
          return;
        }
        setConnectionState("closed");
        reconnectTimer = window.setTimeout(connect, 1500);
      };

      socket.onerror = () => {
        socket?.close();
      };
    };

    connect();

    return () => {
      disposed = true;
      if (typeof reconnectTimer === "number") {
        window.clearTimeout(reconnectTimer);
      }
      socket?.close();
    };
  }, [selectedSymbol]);

  const updateOrderField = <K extends keyof OrderRequest>(key: K, value: OrderRequest[K]) => {
    setOrderForm((prev) => ({ ...prev, [key]: value }));
  };

  const handleSubmitOrder = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setIsSubmittingOrder(true);
    setActionMessage("");
    try {
      const payload: OrderRequest = {
        ...orderForm,
        price: orderForm.type === "MARKET" && orderForm.price.trim() === "" ? "0" : orderForm.price,
      };
      const response = await createOrder(payload);
      setLastOrder(response);
      setActionMessage(`주문 접수 완료 · ${response.orderId}`);
      void loadSymbolData(selectedSymbol);
    } catch (error) {
      setActionMessage(`주문 실패 · ${toErrorMessage(error)}`);
    } finally {
      setIsSubmittingOrder(false);
    }
  };

  const handleCancelLastOrder = async () => {
    if (!lastOrder) {
      return;
    }
    try {
      const canceled = await cancelOrder(lastOrder.orderId);
      setLastOrder(canceled);
      setActionMessage(`주문 취소 완료 · ${canceled.orderId}`);
    } catch (error) {
      setActionMessage(`취소 실패 · ${toErrorMessage(error)}`);
    }
  };

  const handleRefreshOrder = async () => {
    if (!lastOrder) {
      return;
    }
    try {
      const latest = await fetchOrder(lastOrder.orderId);
      setLastOrder(latest);
      setActionMessage(`주문 상태 갱신 · ${latest.status}`);
    } catch (error) {
      setActionMessage(`상태 조회 실패 · ${toErrorMessage(error)}`);
    }
  };

  const handleSeedTrade = async () => {
    setIsSeedingTrade(true);
    const anchorPrice = selectedTicker?.lastPrice ?? 100000000;
    const nextPrice = Math.max(1, Math.round(anchorPrice * (1 + (Math.random() - 0.5) * 0.006)));
    const nextQty = Math.max(1, Math.round((Math.random() * 3 + 1) * 1000));

    try {
      await postSmokeTrade(selectedSymbol, String(nextPrice), String(nextQty));
      setActionMessage(`샘플 체결 전송 · ${selectedSymbol} ${formatPrice(nextPrice)}`);
    } catch (error) {
      setActionMessage(`샘플 체결 실패 · ${toErrorMessage(error)}`);
    } finally {
      setIsSeedingTrade(false);
    }
  };

  const connectionLabel =
    connectionState === "open"
      ? "LIVE"
      : connectionState === "connecting"
        ? "CONNECTING"
        : "RECONNECTING";
  const connectionClass =
    connectionState === "open"
      ? "status-live"
      : connectionState === "connecting"
        ? "status-warn"
        : "status-down";

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" />
          <span className="brand-text">QX EXCHANGE</span>
        </div>
        <nav className="nav-list">
          {NAV_ITEMS.map((item) => (
            <button key={item} className="nav-item" type="button">
              {item}
            </button>
          ))}
        </nav>
        <div className="top-actions">
          <button type="button" className="btn-ghost">
            Log In
          </button>
          <button type="button" className="btn-primary">
            Sign Up
          </button>
        </div>
      </header>

      <main className="content">
        <section className="hero-grid">
          <article className="hero-left">
            <p className="hero-tag">Web User Alpha</p>
            <h1>
              <span>{formatCount(heroUsers)}</span>
              <br />
              USERS MOVE WITH US
            </h1>
            <p className="hero-subtitle">
              Trading Core / Edge Gateway / Ledger 구조를 기준으로 실시간 시세와 주문 플로우를 연결한
              사용자 웹 UI입니다.
            </p>
            <div className="hero-stats">
              <div>
                <p>24h Quote Volume</p>
                <strong>{formatCompact(selectedTicker?.quoteVolume24h ?? 0)}</strong>
              </div>
              <div>
                <p>Band Width</p>
                <strong>{formatSignedPercent(bandPercent)}</strong>
              </div>
              <div>
                <p>WS State</p>
                <strong>{connectionLabel}</strong>
              </div>
            </div>
            <div className="hero-signup">
              <input type="text" placeholder="Email / Phone number" />
              <button type="button">Start Trading</button>
            </div>
          </article>

          <div className="hero-right">
            <article className="panel">
              <div className="panel-head">
                <h3>Popular</h3>
                <span>KRW Market</span>
              </div>
              <div className="market-list">
                {WATCH_SYMBOLS.map((symbol) => {
                  const row = marketRows.find((item) => item.symbol === symbol) ?? null;
                  const middle = row ? (row.high24h + row.low24h) / 2 : 0;
                  const change = middle > 0 && row ? ((row.lastPrice - middle) / middle) * 100 : 0;
                  return (
                    <button
                      key={symbol}
                      className={`market-row ${selectedSymbol === symbol ? "active" : ""}`}
                      onClick={() => setSelectedSymbol(symbol)}
                      type="button"
                    >
                      <div className="market-symbol">
                        <strong>{symbol}</strong>
                        <span>{row ? formatCompact(row.volume24h) : "No data"}</span>
                      </div>
                      <div className="market-price">
                        <strong>{row ? formatPrice(row.lastPrice) : "-"}</strong>
                        <span className={change >= 0 ? "text-up" : "text-down"}>
                          {formatSignedPercent(change)}
                        </span>
                      </div>
                    </button>
                  );
                })}
              </div>
            </article>

            <article className="panel">
              <div className="panel-head">
                <h3>System Feed</h3>
                <span>Architecture notes</span>
              </div>
              <ul className="news-list">
                {NEWS_HEADLINES.map((headline) => (
                  <li key={headline}>{headline}</li>
                ))}
              </ul>
            </article>
          </div>
        </section>

        <section className="terminal-grid">
          <article className="panel ticker-panel">
            <div className="panel-head">
              <h3>{selectedSymbol}</h3>
              <span className={`stream-status ${connectionClass}`}>{connectionLabel}</span>
            </div>

            <div className="ticker-top">
              <p className="ticker-price">
                {selectedTicker ? formatPrice(selectedTicker.lastPrice) : "Waiting for ticker..."}
              </p>
              <button
                type="button"
                className="btn-primary"
                disabled={isSeedingTrade}
                onClick={handleSeedTrade}
              >
                {isSeedingTrade ? "Publishing..." : "Push Sample Trade"}
              </button>
            </div>

            <div className="kpi-grid">
              <div>
                <p>High 24h</p>
                <strong>{selectedTicker ? formatPrice(selectedTicker.high24h) : "-"}</strong>
              </div>
              <div>
                <p>Low 24h</p>
                <strong>{selectedTicker ? formatPrice(selectedTicker.low24h) : "-"}</strong>
              </div>
              <div>
                <p>Volume 24h</p>
                <strong>{selectedTicker ? formatCompact(selectedTicker.volume24h) : "-"}</strong>
              </div>
              <div>
                <p>Candle ({candle?.interval ?? "1m"})</p>
                <strong>{candle ? formatPrice(candle.close) : "-"}</strong>
              </div>
            </div>

            {loadingSymbol && <p className="message">심볼 로딩 중...</p>}
            {panelError && <p className="message error">{panelError}</p>}
            {actionMessage && <p className="message">{actionMessage}</p>}
          </article>

          <article className="panel trades-panel">
            <div className="panel-head">
              <h3>Recent Trades</h3>
              <span>last 30</span>
            </div>
            <div className="trade-table">
              <div className="trade-row trade-head">
                <span>Price</span>
                <span>Qty</span>
                <span>Seq</span>
                <span>Time</span>
              </div>
              {trades.length === 0 && <p className="placeholder">Trade feed is empty. Push sample trade.</p>}
              {trades.map((trade) => (
                <div className="trade-row" key={`${trade.tradeId}-${trade.seq}`}>
                  <span>{formatPrice(trade.price)}</span>
                  <span>{formatQty(trade.qty)}</span>
                  <span>{trade.seq}</span>
                  <span>{new Date(trade.ts).toLocaleTimeString("ko-KR", { hour12: false })}</span>
                </div>
              ))}
            </div>
          </article>

          <article className="panel order-panel">
            <div className="panel-head">
              <h3>Create Order</h3>
              <span>/v1/orders</span>
            </div>

            <form className="order-form" onSubmit={handleSubmitOrder}>
              <label>
                Side
                <select
                  value={orderForm.side}
                  onChange={(event) => updateOrderField("side", event.target.value as "BUY" | "SELL")}
                >
                  <option value="BUY">BUY</option>
                  <option value="SELL">SELL</option>
                </select>
              </label>

              <label>
                Type
                <select
                  value={orderForm.type}
                  onChange={(event) => updateOrderField("type", event.target.value as "LIMIT" | "MARKET")}
                >
                  <option value="LIMIT">LIMIT</option>
                  <option value="MARKET">MARKET</option>
                </select>
              </label>

              <label>
                Price
                <input
                  value={orderForm.price}
                  onChange={(event) => updateOrderField("price", event.target.value)}
                  placeholder="100000000"
                />
              </label>

              <label>
                Qty
                <input
                  value={orderForm.qty}
                  onChange={(event) => updateOrderField("qty", event.target.value)}
                  placeholder="10000"
                />
              </label>

              <label>
                Time In Force
                <select
                  value={orderForm.timeInForce}
                  onChange={(event) =>
                    updateOrderField("timeInForce", event.target.value as "GTC" | "IOC" | "FOK")
                  }
                >
                  <option value="GTC">GTC</option>
                  <option value="IOC">IOC</option>
                  <option value="FOK">FOK</option>
                </select>
              </label>

              <button type="submit" className="btn-primary" disabled={isSubmittingOrder}>
                {isSubmittingOrder ? "Submitting..." : "Submit Order"}
              </button>
            </form>

            <div className="order-actions">
              <button type="button" className="btn-ghost" onClick={handleCancelLastOrder} disabled={!lastOrder}>
                Cancel Last
              </button>
              <button type="button" className="btn-ghost" onClick={handleRefreshOrder} disabled={!lastOrder}>
                Refresh
              </button>
            </div>

            {lastOrder ? (
              <div className="order-result">
                <p>orderId: {lastOrder.orderId}</p>
                <p>status: {lastOrder.status}</p>
                <p>seq: {lastOrder.seq}</p>
              </div>
            ) : (
              <p className="placeholder">아직 제출된 주문이 없습니다.</p>
            )}
          </article>

          <article className="panel orderbook-panel">
            <div className="panel-head">
              <h3>Orderbook Snapshot</h3>
              <span>{selectedSymbol} depth {orderbook?.depth ?? 20}</span>
            </div>

            <div className="book-grid">
              <div className="book-column">
                <h4>Bids</h4>
                {orderbookBids.length === 0 && <p className="placeholder">No bid depth in current backend mock.</p>}
                {orderbookBids.map((level) => (
                  <div className="book-row" key={`bid-${level.price}-${level.qty}`}>
                    <span>{formatPrice(level.price)}</span>
                    <span>{formatQty(level.qty)}</span>
                  </div>
                ))}
              </div>

              <div className="book-column">
                <h4>Asks</h4>
                {orderbookAsks.length === 0 && <p className="placeholder">No ask depth in current backend mock.</p>}
                {orderbookAsks.map((level) => (
                  <div className="book-row" key={`ask-${level.price}-${level.qty}`}>
                    <span>{formatPrice(level.price)}</span>
                    <span>{formatQty(level.qty)}</span>
                  </div>
                ))}
              </div>
            </div>
          </article>
        </section>
      </main>
    </div>
  );
}
