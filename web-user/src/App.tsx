import { type FormEvent, type KeyboardEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  cancelOrder,
  clearSessionToken,
  createOrder,
  fetchCandles,
  fetchMe,
  fetchOrder,
  fetchOrderbook,
  fetchPortfolio,
  fetchTicker,
  fetchTrades,
  getWsUrl,
  logout,
  postSmokeTrade,
  setSessionToken,
  signIn,
  signUp,
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
  AuthUser,
  BalanceItem,
  OrderRequest,
  OrderResponse,
  OrderbookResponse,
  PortfolioResponse,
  RawTickerData,
  WsMessage,
} from "./types";

const WATCH_SYMBOLS = ["BTC-KRW", "ETH-KRW", "SOL-KRW", "XRP-KRW", "BNB-KRW"];
type NavPath =
  | "/"
  | "/buy-crypto"
  | "/markets"
  | "/trade"
  | "/futures"
  | "/earn"
  | "/square"
  | "/assets"
  | "/login"
  | "/signup";

const NAV_ITEMS: Array<{ label: string; path: NavPath }> = [
  { label: "Buy Crypto", path: "/buy-crypto" },
  { label: "Markets", path: "/markets" },
  { label: "Trade", path: "/trade" },
  { label: "Futures", path: "/futures" },
  { label: "Earn", path: "/earn" },
  { label: "Square", path: "/square" },
  { label: "Assets", path: "/assets" },
];

const VALID_PATHS: ReadonlySet<string> = new Set([
  "/",
  "/login",
  "/signup",
  ...NAV_ITEMS.map((item) => item.path),
]);
const NEWS_HEADLINES = [
  "Engine WAL durability path is now wired to Web User feed.",
  "Ledger reconciliation guard remains append-only by policy.",
  "Candle stream now supports gap resume from last seen seq.",
  "Edge gateway replay defense keeps duplicate signatures out.",
];
const SESSION_TOKEN_KEY = "qx.session.token";

const MARKETS_PRIMARY_TABS = ["Overview", "Trading Data", "AI Select", "Token Unlock"] as const;
const MARKETS_ASSET_TABS = ["Favorites", "Cryptos", "Spot", "Futures", "Alpha", "New", "Zones"] as const;
const MARKETS_CATEGORY_CHIPS = [
  "All",
  "BNB Chain",
  "Solana",
  "RWA",
  "Meme",
  "Payments",
  "AI",
  "Layer 1 / Layer 2",
  "Metaverse",
  "Seed",
  "Launchpool",
  "Megadrop",
  "Gaming",
] as const;
const MARKETS_CHART_RANGES = ["1D", "7D", "1M", "3M", "1Y", "YTD"] as const;

type MarketsPrimaryTab = (typeof MARKETS_PRIMARY_TABS)[number];
type MarketsAssetTab = (typeof MARKETS_ASSET_TABS)[number];
type MarketsCategoryChip = (typeof MARKETS_CATEGORY_CHIPS)[number];
type MarketsRange = (typeof MARKETS_CHART_RANGES)[number];
type MarketsMode = "overview" | "detail";

type SymbolMeta = {
  ticker: string;
  name: string;
  color: string;
  categories: MarketsCategoryChip[];
  isNew?: boolean;
};

type MarketBoardRow = {
  symbol: string;
  ticker: string;
  name: string;
  color: string;
  price: number;
  high24h: number;
  low24h: number;
  volume24h: number;
  quoteVolume24h: number;
  change24h: number;
  categories: MarketsCategoryChip[];
  isNew: boolean;
  live: boolean;
  updatedAt: number;
};

const SYMBOL_META: Record<string, SymbolMeta> = {
  "BTC-KRW": {
    ticker: "BTC",
    name: "Bitcoin",
    color: "#f7931a",
    categories: ["All", "Layer 1 / Layer 2"],
  },
  "ETH-KRW": {
    ticker: "ETH",
    name: "Ethereum",
    color: "#627eea",
    categories: ["All", "Layer 1 / Layer 2"],
  },
  "BNB-KRW": {
    ticker: "BNB",
    name: "BNB",
    color: "#f0b90b",
    categories: ["All", "BNB Chain", "Launchpool"],
  },
  "SOL-KRW": {
    ticker: "SOL",
    name: "Solana",
    color: "#28d7c5",
    categories: ["All", "Solana", "Layer 1 / Layer 2"],
    isNew: true,
  },
  "XRP-KRW": {
    ticker: "XRP",
    name: "XRP",
    color: "#23292f",
    categories: ["All", "Payments"],
  },
};

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

type SessionView = {
  token: string;
  user: AuthUser;
  expiresAt: number;
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

function normalizePath(pathname: string): NavPath {
  if (VALID_PATHS.has(pathname)) {
    return pathname as NavPath;
  }
  return "/";
}

function buildLinePath(values: number[], width: number, height: number): string {
  if (values.length === 0) {
    return "";
  }
  const max = Math.max(...values);
  const min = Math.min(...values);
  const range = Math.max(max - min, 1);
  return values
    .map((value, index) => {
      const x = (index / Math.max(values.length - 1, 1)) * width;
      const y = height - ((value - min) / range) * height;
      return `${index === 0 ? "M" : "L"} ${x.toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(" ");
}

function buildAreaPath(values: number[], width: number, height: number): string {
  if (values.length === 0) {
    return "";
  }
  const line = buildLinePath(values, width, height);
  return `${line} L ${width} ${height} L 0 ${height} Z`;
}

function formatAssetAmount(currency: string, value: number): string {
  if (currency === "KRW") {
    return formatPrice(value);
  }
  return new Intl.NumberFormat("en-US", {
    minimumFractionDigits: value < 1 ? 4 : 2,
    maximumFractionDigits: 8,
  }).format(value);
}

export default function App() {
  const [selectedSymbol, setSelectedSymbol] = useState<string>(WATCH_SYMBOLS[0]);
  const [marketRows, setMarketRows] = useState<TickerView[]>([]);
  const [ticker, setTicker] = useState<TickerView | null>(null);
  const [trades, setTrades] = useState<TradeView[]>([]);
  const [candle, setCandle] = useState<CandleView | null>(null);
  const [candleSeries, setCandleSeries] = useState<CandleView[]>([]);
  const [orderbook, setOrderbook] = useState<OrderbookResponse | null>(null);

  const [connectionState, setConnectionState] = useState<ConnectionState>("connecting");
  const [loadingSymbol, setLoadingSymbol] = useState<boolean>(false);
  const [panelError, setPanelError] = useState<string>("");
  const [actionMessage, setActionMessage] = useState<string>("");

  const [isSubmittingOrder, setIsSubmittingOrder] = useState<boolean>(false);
  const [isSeedingTrade, setIsSeedingTrade] = useState<boolean>(false);
  const [lastOrder, setLastOrder] = useState<OrderResponse | null>(null);
  const [currentPath, setCurrentPath] = useState<NavPath>(() => normalizePath(window.location.pathname));
  const [marketsMode, setMarketsMode] = useState<MarketsMode>("overview");
  const [marketsPrimaryTab, setMarketsPrimaryTab] = useState<MarketsPrimaryTab>("Overview");
  const [marketsAssetTab, setMarketsAssetTab] = useState<MarketsAssetTab>("Spot");
  const [marketsCategory, setMarketsCategory] = useState<MarketsCategoryChip>("All");
  const [marketsRange, setMarketsRange] = useState<MarketsRange>("1D");
  const [marketsFocusSymbol, setMarketsFocusSymbol] = useState<string>(WATCH_SYMBOLS[0]);
  const [spotOrderType, setSpotOrderType] = useState<"LIMIT" | "MARKET">("LIMIT");
  const [spotBuyPrice, setSpotBuyPrice] = useState<string>("");
  const [spotSellPrice, setSpotSellPrice] = useState<string>("");
  const [spotBuyQty, setSpotBuyQty] = useState<string>("0.01");
  const [spotSellQty, setSpotSellQty] = useState<string>("0.01");
  const [isSubmittingSpotSide, setIsSubmittingSpotSide] = useState<"BUY" | "SELL" | null>(null);
  const [spotOrderMessage, setSpotOrderMessage] = useState<string>("");
  const [session, setSession] = useState<SessionView | null>(null);
  const [authEmail, setAuthEmail] = useState<string>("");
  const [authPassword, setAuthPassword] = useState<string>("");
  const [authMessage, setAuthMessage] = useState<string>("");
  const [isSubmittingAuth, setIsSubmittingAuth] = useState<boolean>(false);
  const [portfolio, setPortfolio] = useState<PortfolioResponse | null>(null);
  const [isLoadingPortfolio, setIsLoadingPortfolio] = useState<boolean>(false);
  const [portfolioMessage, setPortfolioMessage] = useState<string>("");
  const [orderForm, setOrderForm] = useState<OrderRequest>({
    symbol: WATCH_SYMBOLS[0],
    side: "BUY",
    type: "LIMIT",
    price: "100000000",
    qty: "10000",
    timeInForce: "GTC",
  });

  const wsSeqRef = useRef<number>(0);

  useEffect(() => {
    const onPopState = () => {
      setCurrentPath(normalizePath(window.location.pathname));
    };
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  useEffect(() => {
    const token = window.localStorage.getItem(SESSION_TOKEN_KEY);
    if (!token) {
      clearSessionToken();
      return;
    }
    setSessionToken(token);
    void (async () => {
      try {
        const me = await fetchMe();
        setSession({ token, user: me.user, expiresAt: 0 });
      } catch {
        clearSessionToken();
        window.localStorage.removeItem(SESSION_TOKEN_KEY);
        setSession(null);
      }
    })();
  }, []);

  useEffect(() => {
    if (currentPath !== "/markets") {
      return;
    }
    setMarketsMode("overview");
    setMarketsPrimaryTab("Overview");
    setMarketsAssetTab("Spot");
    setMarketsCategory("All");
  }, [currentPath]);

  useEffect(() => {
    if (!WATCH_SYMBOLS.includes(selectedSymbol)) {
      return;
    }
    setMarketsFocusSymbol(selectedSymbol);
  }, [selectedSymbol]);

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

  const marketUniverse = useMemo<MarketBoardRow[]>(() => {
    const liveBySymbol = new Map(marketRows.map((row) => [row.symbol, row]));
    return WATCH_SYMBOLS.map((symbol) => {
      const live = liveBySymbol.get(symbol);
      const meta = SYMBOL_META[symbol] ?? {
        ticker: symbol.split("-")[0],
        name: symbol.split("-")[0],
        color: "#3c4f78",
        categories: ["All"] as MarketsCategoryChip[],
      };
      const price = live?.lastPrice ?? 0;
      const high24h = live?.high24h ?? 0;
      const low24h = live?.low24h ?? 0;
      const volume24h = live?.volume24h ?? 0;
      const quoteVolume24h = live?.quoteVolume24h ?? 0;
      const mid = high24h > 0 && low24h > 0 ? (high24h + low24h) / 2 : 0;
      const change24h = mid > 0 ? ((price - mid) / mid) * 100 : 0;

      return {
        symbol,
        ticker: meta.ticker,
        name: meta.name,
        color: meta.color,
        price,
        high24h,
        low24h,
        volume24h,
        quoteVolume24h,
        change24h,
        categories: meta.categories,
        isNew: Boolean(meta.isNew),
        live: Boolean(live),
        updatedAt: live?.ts ?? 0,
      };
    });
  }, [marketRows]);

  const apiMarketRows = useMemo(() => {
    return marketUniverse.filter((row) => row.live && row.price > 0);
  }, [marketUniverse]);

  const focusMarket = useMemo(() => {
    return apiMarketRows.find((row) => row.symbol === marketsFocusSymbol) ?? apiMarketRows[0] ?? null;
  }, [apiMarketRows, marketsFocusSymbol]);

  const filteredMarketRows = useMemo(() => {
    let rows = [...apiMarketRows];
    if (marketsAssetTab === "Favorites") {
      rows = rows.filter((row) => row.ticker === "BTC" || row.ticker === "ETH" || row.ticker === "BNB");
    } else if (marketsAssetTab === "New") {
      rows = rows.filter((row) => row.isNew);
    } else if (marketsAssetTab === "Futures") {
      rows = rows.filter((row) => row.ticker === "BTC" || row.ticker === "ETH" || row.ticker === "SOL");
    }

    if (marketsCategory !== "All") {
      rows = rows.filter((row) => row.categories.includes(marketsCategory));
    }
    return rows.sort((a, b) => b.quoteVolume24h - a.quoteVolume24h);
  }, [apiMarketRows, marketsAssetTab, marketsCategory]);

  const hotMarkets = useMemo(() => {
    return [...apiMarketRows].sort((a, b) => b.quoteVolume24h - a.quoteVolume24h).slice(0, 3);
  }, [apiMarketRows]);

  const newMarkets = useMemo(() => {
    const rows = [...apiMarketRows]
      .filter((row) => row.isNew)
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .slice(0, 3);
    if (rows.length > 0) {
      return rows;
    }
    return [...apiMarketRows].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 3);
  }, [apiMarketRows]);

  const topGainers = useMemo(() => {
    return [...apiMarketRows].sort((a, b) => b.change24h - a.change24h).slice(0, 3);
  }, [apiMarketRows]);

  const topVolumes = useMemo(() => {
    return [...apiMarketRows].sort((a, b) => b.volume24h - a.volume24h).slice(0, 3);
  }, [apiMarketRows]);

  const detailSeries = useMemo(() => {
    if (!focusMarket || focusMarket.symbol !== selectedSymbol) {
      return [];
    }
    const pointsByRange: Record<MarketsRange, number> = {
      "1D": 96,
      "7D": 140,
      "1M": 180,
      "3M": 220,
      "1Y": 260,
      YTD: 240,
    };
    const limit = pointsByRange[marketsRange];
    const fromCandles = candleSeries.map((point) => point.close).filter((value) => value > 0);
    if (fromCandles.length >= 2) {
      return fromCandles.slice(-limit);
    }
    const fromTrades = [...trades]
      .reverse()
      .map((trade) => trade.price)
      .filter((value) => value > 0);
    return fromTrades.slice(-limit);
  }, [candleSeries, focusMarket, marketsRange, selectedSymbol, trades]);

  const detailLinePath = useMemo(() => buildLinePath(detailSeries, 760, 320), [detailSeries]);
  const detailAreaPath = useMemo(() => buildAreaPath(detailSeries, 760, 320), [detailSeries]);
  const detailCurrentPriceKrw = useMemo(() => {
    if (focusMarket?.symbol === selectedSymbol && selectedTicker?.lastPrice) {
      return Math.max(1, Math.round(selectedTicker.lastPrice));
    }
    if (detailSeries.length > 0) {
      return Math.max(1, Math.round(detailSeries[detailSeries.length - 1]));
    }
    return Math.max(1, Math.round(focusMarket?.price ?? 0));
  }, [detailSeries, focusMarket?.price, focusMarket?.symbol, selectedSymbol, selectedTicker?.lastPrice]);

  const detailBids = useMemo(() => {
    if (focusMarket?.symbol !== selectedSymbol) {
      return [];
    }
    return orderbookBids.slice(0, 14);
  }, [focusMarket?.symbol, orderbookBids, selectedSymbol]);

  const detailAsks = useMemo(() => {
    if (focusMarket?.symbol !== selectedSymbol) {
      return [];
    }
    return orderbookAsks.slice(0, 14);
  }, [focusMarket?.symbol, orderbookAsks, selectedSymbol]);

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
    validRows.sort((a, b) => WATCH_SYMBOLS.indexOf(a.symbol) - WATCH_SYMBOLS.indexOf(b.symbol));
    setMarketRows(validRows);
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

      const candleRows = candlesResponse.candles
        .map((msg) => toCandleFromMessage(msg))
        .filter((row): row is CandleView => row !== null);
      const latestCandle = candleRows.length > 0 ? candleRows[candleRows.length - 1] : null;
      setCandle(latestCandle);
      setCandleSeries(candleRows.slice(-260));

      setOrderbook(orderbookResponse);
    } catch (error) {
      setPanelError(`시세 로드 실패 · ${toErrorMessage(error)}`);
    } finally {
      setLoadingSymbol(false);
    }
  }, []);

  const refreshPortfolioData = useCallback(async () => {
    if (!session) {
      setPortfolio(null);
      return;
    }
    setIsLoadingPortfolio(true);
    try {
      const nextPortfolio = await fetchPortfolio();
      setPortfolio(nextPortfolio);
      setPortfolioMessage("");
    } catch (error) {
      setPortfolioMessage(`잔고 조회 실패 · ${toErrorMessage(error)}`);
    } finally {
      setIsLoadingPortfolio(false);
    }
  }, [session]);

  useEffect(() => {
    void refreshPortfolioData();
  }, [refreshPortfolioData]);

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
    if (!focusMarket) {
      return;
    }
    const defaultPrice = focusMarket.symbol === selectedSymbol && selectedTicker?.lastPrice
      ? Math.max(1, Math.round(selectedTicker.lastPrice))
      : Math.max(1, Math.round(focusMarket.price));
    setSpotOrderType("LIMIT");
    setSpotBuyPrice(String(defaultPrice));
    setSpotSellPrice(String(defaultPrice));
    setSpotBuyQty("0.01");
    setSpotSellQty("0.01");
    setSpotOrderMessage("");
  }, [focusMarket?.symbol]);

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
            setCandleSeries((prev) => {
              const index = prev.findIndex((item) => item.seq === nextCandle.seq);
              if (index >= 0) {
                const replaced = [...prev];
                replaced[index] = nextCandle;
                return replaced.slice(-260);
              }
              return [...prev, nextCandle].slice(-260);
            });
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

  const handleSubmitAuth = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const authMode = currentPath === "/signup" ? "signup" : "login";
    setIsSubmittingAuth(true);
    setAuthMessage("");
    try {
      const response = authMode === "signup"
        ? await signUp(authEmail, authPassword)
        : await signIn(authEmail, authPassword);
      setSessionToken(response.sessionToken);
      window.localStorage.setItem(SESSION_TOKEN_KEY, response.sessionToken);
      setSession({
        token: response.sessionToken,
        user: response.user,
        expiresAt: response.expiresAt,
      });
      setAuthPassword("");
      setAuthMessage(authMode === "signup" ? "회원가입 완료 · 로그인 되었습니다." : "로그인 성공");
      setCurrentPath("/assets");
      window.history.pushState({}, "", "/assets");
    } catch (error) {
      setAuthMessage(`인증 실패 · ${toErrorMessage(error)}`);
    } finally {
      setIsSubmittingAuth(false);
    }
  };

  const handleLogout = async () => {
    try {
      await logout();
    } catch {
      // Ignore remote logout failures and clear local session.
    }
    clearSessionToken();
    window.localStorage.removeItem(SESSION_TOKEN_KEY);
    setSession(null);
    setPortfolio(null);
    setPortfolioMessage("");
    setSpotOrderMessage("");
    if (currentPath === "/assets") {
      handleNavClick("/");
    }
  };

  const handleSubmitOrder = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!session) {
      setActionMessage("로그인 후 주문 가능합니다.");
      return;
    }
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
      void refreshPortfolioData();
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
      void refreshPortfolioData();
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

  const handleSubmitSpotOrder = async (side: "BUY" | "SELL") => {
    if (!session) {
      setSpotOrderMessage("로그인 후 주문 가능합니다.");
      return;
    }
    if (!focusMarket) {
      return;
    }
    const symbol = focusMarket.symbol;
    const rawPrice = side === "BUY" ? spotBuyPrice : spotSellPrice;
    const rawQty = side === "BUY" ? spotBuyQty : spotSellQty;
    const normalizedPrice = spotOrderType === "MARKET" ? "0" : rawPrice.trim();
    const normalizedQty = rawQty.trim();

    if (normalizedQty === "" || Number(normalizedQty) <= 0) {
      setSpotOrderMessage("수량을 올바르게 입력해 주세요.");
      return;
    }
    if (spotOrderType !== "MARKET" && (normalizedPrice === "" || Number(normalizedPrice) <= 0)) {
      setSpotOrderMessage("가격을 올바르게 입력해 주세요.");
      return;
    }

    setIsSubmittingSpotSide(side);
    setSpotOrderMessage("");
    try {
      const response = await createOrder({
        symbol,
        side,
        type: spotOrderType,
        price: normalizedPrice,
        qty: normalizedQty,
        timeInForce: "GTC",
      });
      setLastOrder(response);
      setSpotOrderMessage(`${side} 주문 접수 · ${response.orderId}`);
      void refreshPortfolioData();
      if (symbol === selectedSymbol) {
        void loadSymbolData(symbol);
      }
    } catch (error) {
      setSpotOrderMessage(`${side} 주문 실패 · ${toErrorMessage(error)}`);
    } finally {
      setIsSubmittingSpotSide(null);
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

  const handleNavClick = (path: NavPath) => {
    if (path === currentPath) {
      if (path === "/markets") {
        setMarketsMode("overview");
      }
      window.scrollTo({ top: 0, behavior: "smooth" });
      return;
    }
    window.history.pushState({}, "", path);
    setCurrentPath(path);
    if (path === "/markets") {
      setMarketsMode("overview");
    }
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const handleBrandKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      handleNavClick("/");
    }
  };

  const renderRouteBanner = (title: string, subtitle: string, description: string) => (
    <section className="panel route-banner">
      <div className="panel-head">
        <h3>{title}</h3>
        <span>{subtitle}</span>
      </div>
      <p className="hero-subtitle">{description}</p>
    </section>
  );

  const renderMarketPanel = (title = "Popular", subtitle = "KRW Market") => (
    <article className="panel market-panel">
      <div className="panel-head">
        <h3>{title}</h3>
        <span>{subtitle}</span>
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
                <span className={change >= 0 ? "text-up" : "text-down"}>{formatSignedPercent(change)}</span>
              </div>
            </button>
          );
        })}
      </div>
    </article>
  );

  const renderSystemFeedPanel = (title = "System Feed", subtitle = "Architecture notes") => (
    <article className="panel">
      <div className="panel-head">
        <h3>{title}</h3>
        <span>{subtitle}</span>
      </div>
      <ul className="news-list">
        {NEWS_HEADLINES.map((headline) => (
          <li key={headline}>{headline}</li>
        ))}
      </ul>
    </article>
  );

  const renderTickerPanel = (title = selectedSymbol) => (
    <article className="panel ticker-panel">
      <div className="panel-head">
        <h3>{title}</h3>
        <span className={`stream-status ${connectionClass}`}>{connectionLabel}</span>
      </div>

      <div className="ticker-top">
        <p className="ticker-price">
          {selectedTicker ? formatPrice(selectedTicker.lastPrice) : "Waiting for ticker..."}
        </p>
        <button type="button" className="btn-primary" disabled={isSeedingTrade} onClick={handleSeedTrade}>
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
  );

  const renderTradesPanel = (title = "Recent Trades", subtitle = "last 30") => (
    <article className="panel trades-panel">
      <div className="panel-head">
        <h3>{title}</h3>
        <span>{subtitle}</span>
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
  );

  const renderOrderPanel = () => (
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
            onChange={(event) => updateOrderField("timeInForce", event.target.value as "GTC" | "IOC" | "FOK")}
          >
            <option value="GTC">GTC</option>
            <option value="IOC">IOC</option>
            <option value="FOK">FOK</option>
          </select>
        </label>

        <button type="submit" className="btn-primary" disabled={isSubmittingOrder || !session}>
          {!session ? "Login Required" : isSubmittingOrder ? "Submitting..." : "Submit Order"}
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
  );

  const renderOrderbookPanel = () => (
    <article className="panel orderbook-panel">
      <div className="panel-head">
        <h3>Orderbook Snapshot</h3>
        <span>
          {selectedSymbol} depth {orderbook?.depth ?? 20}
        </span>
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
  );

  const handleOpenMarketDetail = (row: MarketBoardRow) => {
    setMarketsFocusSymbol(row.symbol);
    setMarketsMode("detail");
    if (WATCH_SYMBOLS.includes(row.symbol) && row.symbol !== selectedSymbol) {
      setSelectedSymbol(row.symbol);
    }
  };

  const renderMarketsCard = (title: string, rows: MarketBoardRow[]) => (
    <article className="markets-card" key={title}>
      <div className="markets-card-head">
        <h4>{title}</h4>
        <button type="button" onClick={() => setMarketsMode("overview")}>
          More ›
        </button>
      </div>
      <div className="markets-card-rows">
        {rows.map((row) => (
          <button key={`${title}-${row.symbol}`} type="button" className="markets-mini-row" onClick={() => handleOpenMarketDetail(row)}>
            <span className="markets-token">
              <span className="token-badge" style={{ backgroundColor: row.color }}>
                {row.ticker.slice(0, 1)}
              </span>
              <strong>{row.ticker}</strong>
            </span>
            <span>{row.price > 0 ? formatPrice(row.price) : "-"}</span>
            <span className={row.change24h >= 0 ? "text-up" : "text-down"}>
              {row.price > 0 ? formatSignedPercent(row.change24h) : "-"}
            </span>
          </button>
        ))}
      </div>
    </article>
  );

  const renderMarketsOverview = () => (
    <section className="markets-shell">
      <div className="markets-primary-tabs">
        {MARKETS_PRIMARY_TABS.map((tab) => (
          <button
            key={tab}
            type="button"
            className={`markets-primary-tab ${marketsPrimaryTab === tab ? "active" : ""}`}
            onClick={() => setMarketsPrimaryTab(tab)}
          >
            {tab}
          </button>
        ))}
      </div>

      <div className="markets-card-grid">
        {renderMarketsCard("Hot", hotMarkets)}
        {renderMarketsCard("New", newMarkets)}
        {renderMarketsCard("Top Gainer", topGainers)}
        {renderMarketsCard("Top Volume", topVolumes)}
      </div>

      <div className="markets-asset-bar">
        <div className="markets-asset-tabs">
          {MARKETS_ASSET_TABS.map((tab) => (
            <button
              key={tab}
              type="button"
              className={`markets-asset-tab ${marketsAssetTab === tab ? "active" : ""}`}
              onClick={() => setMarketsAssetTab(tab)}
            >
              {tab}
            </button>
          ))}
        </div>
        <div className="markets-tools">
          <button type="button">⌕</button>
          <button type="button">◴</button>
        </div>
      </div>

      <div className="markets-category-row">
        {MARKETS_CATEGORY_CHIPS.map((chip) => (
          <button
            key={chip}
            type="button"
            className={`markets-category-chip ${marketsCategory === chip ? "active" : ""}`}
            onClick={() => setMarketsCategory(chip)}
          >
            {chip}
            {chip === "Launchpool" || chip === "Megadrop" ? <span className="markets-chip-flag">New</span> : null}
          </button>
        ))}
      </div>

      <article className="panel markets-table-panel">
        <div className="panel-head">
          <h3>Top Tokens by 24h Quote Volume</h3>
          <span>24h snapshot</span>
        </div>
        <p className="markets-table-caption">
          This board is built from live ticker API snapshots and realtime websocket updates.
        </p>
        <div className="markets-table-header">
          <span>Name</span>
          <span>Price</span>
          <span>Change</span>
          <span>24h Volume</span>
          <span>24h Quote</span>
          <span>Actions</span>
        </div>
        <div className="markets-table-body">
          {filteredMarketRows.map((row) => (
            <button key={`table-${row.symbol}`} type="button" className="markets-table-row" onClick={() => handleOpenMarketDetail(row)}>
              <span className="markets-token-cell">
                <span className="token-badge" style={{ backgroundColor: row.color }}>
                  {row.ticker.slice(0, 1)}
                </span>
                <span>
                  <strong>{row.ticker}</strong>
                  <small>{row.name}</small>
                </span>
              </span>
              <span>{formatPrice(row.price)}</span>
              <span className={row.change24h >= 0 ? "text-up" : "text-down"}>
                {formatSignedPercent(row.change24h)}
              </span>
              <span>{formatCompact(row.volume24h)}</span>
              <span>{formatCompact(row.quoteVolume24h)}</span>
              <span className="markets-action-icons">⧉ Ʉ</span>
            </button>
          ))}
          {filteredMarketRows.length === 0 ? (
            <p className="placeholder">No tokens matched this filter. Pick another category.</p>
          ) : null}
        </div>
      </article>
    </section>
  );

  const renderMarketsDetail = () => {
    if (!focusMarket) {
      return (
        <section className="markets-shell">
          <p className="placeholder">No market selected.</p>
        </section>
      );
    }

    const currentPrice = detailSeries.length > 0 ? detailSeries[detailSeries.length - 1] : focusMarket.price;
    const minPrice = detailSeries.length > 0 ? Math.min(...detailSeries) : currentPrice;
    const maxPrice = detailSeries.length > 0 ? Math.max(...detailSeries) : currentPrice;
    const updatedAt = new Date().toISOString().slice(0, 19).replace("T", " ");
    const sideRows = (filteredMarketRows.length > 0 ? filteredMarketRows : apiMarketRows).slice(0, 14);
    const tapeRows = trades.slice(0, 18);

    return (
      <section className="markets-shell">
        <div className="markets-breadcrumb">
          <button type="button" onClick={() => setMarketsMode("overview")}>
            Home
          </button>
          <span>›</span>
          <button type="button" onClick={() => setMarketsMode("overview")}>
            Crypto prices
          </button>
          <span>›</span>
          <span>
            {focusMarket.name} Price ({focusMarket.ticker})
          </span>
        </div>

        <div className="markets-trade-layout">
          <aside className="panel markets-book-panel">
            <div className="panel-head">
              <h3>Order Book</h3>
              <span>live</span>
            </div>
            <div className="markets-book-head">
              <span>Price (KRW)</span>
              <span>Amount ({focusMarket.ticker})</span>
            </div>
            <div className="markets-book-list">
              {detailAsks.map((level) => (
                <div key={`ask-${level.price}-${level.qty}`} className="markets-book-row ask">
                  <span>{formatPrice(level.price)}</span>
                  <span>{formatQty(level.qty)}</span>
                </div>
              ))}
            </div>
            <p className="markets-mid-price">{formatPrice(detailCurrentPriceKrw)}</p>
            <div className="markets-book-list">
              {detailBids.map((level) => (
                <div key={`bid-${level.price}-${level.qty}`} className="markets-book-row bid">
                  <span>{formatPrice(level.price)}</span>
                  <span>{formatQty(level.qty)}</span>
                </div>
              ))}
            </div>
          </aside>

          <article className="panel markets-chart-panel trade-center">
            <div className="markets-detail-head">
              <div>
                <h2>
                  <span className="token-badge large" style={{ backgroundColor: focusMarket.color }}>
                    {focusMarket.ticker.slice(0, 1)}
                  </span>
                  {focusMarket.name} Price ({focusMarket.ticker})
                </h2>
                <p>
                  {focusMarket.ticker}/<span>KRW</span>: 1 {focusMarket.ticker} equals {formatPrice(currentPrice)}{" "}
                  <strong className={focusMarket.change24h >= 0 ? "text-up" : "text-down"}>
                    {formatSignedPercent(focusMarket.change24h)}
                  </strong>
                </p>
                <div className="markets-mini-stats">
                  <span>24h High {formatPrice(maxPrice)}</span>
                  <span>24h Low {formatPrice(minPrice)}</span>
                  <span>Quote Vol {formatCompact(focusMarket.quoteVolume24h)}</span>
                </div>
              </div>
              <button type="button" className="btn-ghost" onClick={() => setMarketsMode("overview")}>
                Back To Markets
              </button>
            </div>

            <div className="markets-range-tabs">
              {MARKETS_CHART_RANGES.map((range) => (
                <button
                  key={range}
                  type="button"
                  className={marketsRange === range ? "active" : ""}
                  onClick={() => setMarketsRange(range)}
                >
                  {range}
                </button>
              ))}
            </div>

            <div className="markets-chart-wrap">
              <svg viewBox="0 0 760 340" className="markets-chart-svg" preserveAspectRatio="none">
                <defs>
                  <linearGradient id="marketsChartFill" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="rgba(240, 185, 11, 0.55)" />
                    <stop offset="100%" stopColor="rgba(240, 185, 11, 0.02)" />
                  </linearGradient>
                </defs>
                <path d={detailAreaPath} fill="url(#marketsChartFill)" />
                <path d={detailLinePath} fill="none" stroke="#f0b90b" strokeWidth="3" strokeLinecap="round" />
              </svg>
              <div className="markets-chart-y">
                <span>{formatPrice(maxPrice)}</span>
                <span>{formatPrice((maxPrice + minPrice) / 2)}</span>
                <span>{formatPrice(minPrice)}</span>
              </div>
            </div>

            <p className="markets-updated">Page last updated: {updatedAt} (UTC+0)</p>
          </article>

          <aside className="panel markets-side-panel">
            <div className="panel-head">
              <h3>Spot Pairs</h3>
              <span>{marketsAssetTab}</span>
            </div>
            <div className="markets-pair-list">
              {sideRows.map((row) => (
                <button
                  key={`pair-${row.symbol}`}
                  type="button"
                  className={`markets-pair-row ${row.symbol === focusMarket.symbol ? "active" : ""}`}
                  onClick={() => handleOpenMarketDetail(row)}
                >
                  <span>
                    <strong>{row.ticker}/KRW</strong>
                  </span>
                  <span>{formatPrice(row.price)}</span>
                  <span className={row.change24h >= 0 ? "text-up" : "text-down"}>{formatSignedPercent(row.change24h)}</span>
                </button>
              ))}
            </div>
            <div className="markets-side-trades">
              <div className="panel-head">
                <h3>Market Trades</h3>
                <span>recent</span>
              </div>
              {tapeRows.length === 0 ? (
                <p className="placeholder">No trades yet. Push sample trade from trade panel.</p>
              ) : (
                <div className="markets-side-trade-list">
                  {tapeRows.map((trade) => (
                    <div className="markets-side-trade-row" key={`detail-trade-${trade.tradeId}-${trade.seq}`}>
                      <span className={trade.price >= detailCurrentPriceKrw ? "text-up" : "text-down"}>
                        {formatPrice(trade.price)}
                      </span>
                      <span>{formatQty(trade.qty)}</span>
                      <span>{new Date(trade.ts).toLocaleTimeString("ko-KR", { hour12: false })}</span>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </aside>
        </div>

        <article className="panel markets-spot-order-panel">
          <div className="markets-spot-head">
            <div className="markets-spot-mode-tabs">
              <button type="button" className="active">
                Spot
              </button>
              <button type="button">Cross</button>
              <button type="button">Isolated</button>
            </div>
            <div className="markets-spot-type-tabs">
              <button
                type="button"
                className={spotOrderType === "LIMIT" ? "active" : ""}
                onClick={() => setSpotOrderType("LIMIT")}
              >
                Limit
              </button>
              <button
                type="button"
                className={spotOrderType === "MARKET" ? "active" : ""}
                onClick={() => setSpotOrderType("MARKET")}
              >
                Market
              </button>
            </div>
          </div>

          <div className="markets-spot-order-grid">
            <form
              className="markets-order-box"
              onSubmit={(event) => {
                event.preventDefault();
                void handleSubmitSpotOrder("BUY");
              }}
            >
              <h4>Buy {focusMarket.ticker}</h4>
              <label>
                Price
                <input
                  value={spotBuyPrice}
                  onChange={(event) => setSpotBuyPrice(event.target.value)}
                  disabled={spotOrderType === "MARKET"}
                  placeholder={spotOrderType === "MARKET" ? "Market Price" : "Price"}
                />
              </label>
              <label>
                Amount
                <input value={spotBuyQty} onChange={(event) => setSpotBuyQty(event.target.value)} placeholder={`Amount (${focusMarket.ticker})`} />
              </label>
              <button type="submit" className="btn-buy" disabled={isSubmittingSpotSide !== null || !session}>
                {!session ? "Login Required" : isSubmittingSpotSide === "BUY" ? "Submitting..." : `Buy ${focusMarket.ticker}`}
              </button>
            </form>

            <form
              className="markets-order-box"
              onSubmit={(event) => {
                event.preventDefault();
                void handleSubmitSpotOrder("SELL");
              }}
            >
              <h4>Sell {focusMarket.ticker}</h4>
              <label>
                Price
                <input
                  value={spotSellPrice}
                  onChange={(event) => setSpotSellPrice(event.target.value)}
                  disabled={spotOrderType === "MARKET"}
                  placeholder={spotOrderType === "MARKET" ? "Market Price" : "Price"}
                />
              </label>
              <label>
                Amount
                <input
                  value={spotSellQty}
                  onChange={(event) => setSpotSellQty(event.target.value)}
                  placeholder={`Amount (${focusMarket.ticker})`}
                />
              </label>
              <button type="submit" className="btn-sell" disabled={isSubmittingSpotSide !== null || !session}>
                {!session ? "Login Required" : isSubmittingSpotSide === "SELL" ? "Submitting..." : `Sell ${focusMarket.ticker}`}
              </button>
            </form>
          </div>

          {spotOrderMessage ? (
            <p className={`message ${spotOrderMessage.includes("실패") ? "error" : ""}`}>{spotOrderMessage}</p>
          ) : null}
        </article>

        <article className="panel markets-community">
          <div className="panel-head">
            <h3>#{focusMarket.ticker}</h3>
            <span>{formatCompact(focusMarket.volume24h)} discussing</span>
          </div>
          {trades.length === 0 ? (
            <p className="placeholder">No recent discussion clips. Push sample trade to refresh this panel.</p>
          ) : (
            <ul className="news-list">
              {trades.slice(0, 5).map((trade) => (
                <li key={`community-${trade.tradeId}-${trade.seq}`}>
                  {new Date(trade.ts).toLocaleTimeString("ko-KR", { hour12: false })} · {formatPrice(trade.price)} · qty{" "}
                  {formatQty(trade.qty)}
                </li>
              ))}
            </ul>
          )}
        </article>
      </section>
    );
  };

  const renderAssetsPage = () => {
    if (!session) {
      return (
        <>
          {renderRouteBanner(
            "Assets",
            "Portfolio access",
            "로그인 후 보유 코인/잔고/평가금액을 확인하고 매수/매도 주문을 실행할 수 있습니다.",
          )}
          <section className="panel">
            <p className="placeholder">상단에서 이메일/비밀번호로 로그인하거나 회원가입해 주세요.</p>
          </section>
        </>
      );
    }

    const assetRows: BalanceItem[] = portfolio?.assets ?? [];
    const totalAssetValue = portfolio?.totalAssetValue ?? 0;

    return (
      <>
        {renderRouteBanner(
          "My Assets",
          session.user.email,
          "Redis session 기반 인증 계정의 보유자산/평가금액을 실시간 마켓 가격으로 계산합니다.",
        )}
        <section className="panel assets-summary-panel">
          <div className="kpi-grid">
            <div>
              <p>Total Asset Value</p>
              <strong>{formatPrice(totalAssetValue)}</strong>
            </div>
            <div>
              <p>Asset Count</p>
              <strong>{assetRows.length}</strong>
            </div>
            <div>
              <p>Session</p>
              <strong>{session.expiresAt > 0 ? "ACTIVE" : "UNKNOWN"}</strong>
            </div>
            <div>
              <p>Updated</p>
              <strong>
                {portfolio?.updatedAt
                  ? new Date(portfolio.updatedAt).toLocaleTimeString("ko-KR", { hour12: false })
                  : "-"}
              </strong>
            </div>
          </div>
          {isLoadingPortfolio ? <p className="message">잔고 불러오는 중...</p> : null}
          {portfolioMessage ? <p className="message error">{portfolioMessage}</p> : null}
        </section>
        <section className="panel assets-table-panel">
          <div className="panel-head">
            <h3>Balances</h3>
            <span>{session.user.userId}</span>
          </div>
          <div className="assets-table-head">
            <span>Currency</span>
            <span>Available</span>
            <span>Hold</span>
            <span>Total</span>
            <span>Price (KRW)</span>
            <span>Value (KRW)</span>
          </div>
          <div className="assets-table-body">
            {assetRows.map((asset) => (
              <div className="assets-table-row" key={`asset-${asset.currency}`}>
                <span>{asset.currency}</span>
                <span>{formatAssetAmount(asset.currency, asset.available)}</span>
                <span>{formatAssetAmount(asset.currency, asset.hold)}</span>
                <span>{formatAssetAmount(asset.currency, asset.total)}</span>
                <span>{asset.priceKrw !== undefined ? formatPrice(asset.priceKrw) : "-"}</span>
                <span>{asset.valueKrw !== undefined ? formatPrice(asset.valueKrw) : "-"}</span>
              </div>
            ))}
            {assetRows.length === 0 ? <p className="placeholder">아직 보유 자산 정보가 없습니다.</p> : null}
          </div>
        </section>
      </>
    );
  };

  const renderAuthPage = (mode: "login" | "signup") => {
    const isSignUp = mode === "signup";
    if (session) {
      return (
        <>
          {renderRouteBanner(
            isSignUp ? "Sign Up" : "Log In",
            "Already authenticated",
            "이미 로그인되어 있습니다. 자산 페이지에서 잔고와 평가금액을 확인하세요.",
          )}
          <section className="panel">
            <p className="placeholder">{session.user.email} 계정으로 로그인되어 있습니다.</p>
            <button type="button" className="btn-primary inline-action" onClick={() => handleNavClick("/assets")}>
              Go To Assets
            </button>
          </section>
        </>
      );
    }

    return (
      <>
        {renderRouteBanner(
          isSignUp ? "Sign Up" : "Log In",
          "Email / Password",
          "이메일/비밀번호 기반 Redis Session 인증 화면입니다.",
        )}
        <section className="panel auth-page-panel">
          <form className="auth-page-form" onSubmit={handleSubmitAuth}>
            <label>
              Email
              <input
                value={authEmail}
                onChange={(event) => setAuthEmail(event.target.value)}
                type="email"
                placeholder="you@example.com"
                required
              />
            </label>
            <label>
              Password
              <input
                value={authPassword}
                onChange={(event) => setAuthPassword(event.target.value)}
                type="password"
                placeholder="At least 8 characters"
                minLength={8}
                required
              />
            </label>
            <button type="submit" className="btn-primary" disabled={isSubmittingAuth}>
              {isSubmittingAuth ? "Submitting..." : isSignUp ? "Create Account" : "Log In"}
            </button>
            <button
              type="button"
              className="btn-ghost"
              onClick={() => {
                setAuthMessage("");
                handleNavClick(isSignUp ? "/login" : "/signup");
              }}
            >
              {isSignUp ? "Already have account?" : "Need account?"}
            </button>
          </form>
          {authMessage ? (
            <p className={`message ${authMessage.includes("실패") ? "error" : ""}`}>{authMessage}</p>
          ) : null}
        </section>
      </>
    );
  };

  const renderRouteContent = () => {
    switch (currentPath) {
      case "/buy-crypto":
        return (
          <>
            {renderRouteBanner(
              "Buy Crypto",
              "Onboarding + Quote",
              "계정 진입과 KRW 마켓 진입을 한 화면에서 처리하는 랜딩입니다.",
            )}
            <section className="hero-grid">
              <article className="hero-left">
                <p className="hero-tag">Buy Crypto</p>
                <h1>
                  <span>{selectedSymbol}</span>
                  <br />
                  START WITH KRW
                </h1>
                <p className="hero-subtitle">
                  빠르게 심볼을 고르고 체결 샘플을 주입해 실시간 티커/체결 반영을 확인할 수 있습니다.
                </p>
                <div className="hero-signup">
                  <input type="text" placeholder="Email / Phone number" />
                  <button type="button" onClick={() => handleNavClick("/trade")}>
                    Go Trade
                  </button>
                </div>
              </article>
              <div className="hero-right">
                {renderMarketPanel("Buy Market", "KRW symbols")}
                {renderTickerPanel("Live Quote")}
              </div>
            </section>
          </>
        );
      case "/markets":
        return marketsMode === "detail" ? renderMarketsDetail() : renderMarketsOverview();
      case "/trade":
        return (
          <>
            {renderRouteBanner(
              "Trade",
              "Order entry terminal",
              "주문 생성/취소/조회와 실시간 시세를 결합한 트레이드 화면입니다.",
            )}
            <section className="terminal-grid">
              {renderTickerPanel("Trade Terminal")}
              {renderTradesPanel()}
              {renderOrderPanel()}
              {renderOrderbookPanel()}
            </section>
          </>
        );
      case "/futures":
        return (
          <>
            {renderRouteBanner(
              "Futures",
              "Preview mode",
              "선물 엔진 연결 전까지 현물 데이터를 기반으로 한 프리뷰 화면을 제공합니다.",
            )}
            <section className="hero-grid">
              <article className="panel futures-overview">
                <div className="panel-head">
                  <h3>Perpetual Preview</h3>
                  <span>Read-only</span>
                </div>
                <div className="kpi-grid">
                  <div>
                    <p>Mark Price</p>
                    <strong>{selectedTicker ? formatPrice(selectedTicker.lastPrice) : "-"}</strong>
                  </div>
                  <div>
                    <p>Funding (Est.)</p>
                    <strong>{selectedTicker ? formatSignedPercent(bandPercent / 10) : "-"}</strong>
                  </div>
                  <div>
                    <p>Open Interest (Mock)</p>
                    <strong>{selectedTicker ? formatCompact(selectedTicker.quoteVolume24h * 0.14) : "-"}</strong>
                  </div>
                  <div>
                    <p>Risk Band</p>
                    <strong>{formatSignedPercent(bandPercent)}</strong>
                  </div>
                </div>
                <p className="placeholder">실주문은 아직 Spot 경로(`/trade`)만 활성화되어 있습니다.</p>
                <button type="button" className="btn-primary inline-action" onClick={() => handleNavClick("/trade")}>
                  Move To Spot Trade
                </button>
              </article>
              <div className="hero-right">
                {renderTickerPanel("Reference Ticker")}
                {renderSystemFeedPanel("Risk Feed", "Guardrails + tracing")}
              </div>
            </section>
          </>
        );
      case "/earn":
        return (
          <>
            {renderRouteBanner(
              "Earn",
              "Yield products",
              "Earn 상품은 데모 기준의 샘플 APY를 보여주며, 실자금 기능은 연결되지 않습니다.",
            )}
            <section className="panel">
              <div className="panel-head">
                <h3>Earn Catalog</h3>
                <span>alpha preview</span>
              </div>
              <div className="cards-grid">
                <article className="mini-card">
                  <p>Flexible</p>
                  <strong>BTC Flex Save</strong>
                  <span>APY 3.2%</span>
                </article>
                <article className="mini-card">
                  <p>Fixed 30D</p>
                  <strong>ETH Locked</strong>
                  <span>APY 6.4%</span>
                </article>
                <article className="mini-card">
                  <p>Launchpool</p>
                  <strong>BNB Rewards</strong>
                  <span>APY 11.8%</span>
                </article>
              </div>
            </section>
            <section className="hero-grid">
              {renderMarketPanel("Yield Base Markets", "liquidity")}
              {renderTradesPanel("Recent Activity", "for strategy check")}
            </section>
          </>
        );
      case "/square":
        return (
          <>
            {renderRouteBanner(
              "Square",
              "Community + ops feed",
              "서비스 공지와 시스템 피드를 한 곳에서 보는 커뮤니티 허브 화면입니다.",
            )}
            <section className="hero-grid">
              {renderSystemFeedPanel("Square Feed", "community + ops")}
              <article className="panel">
                <div className="panel-head">
                  <h3>Recent Clips</h3>
                  <span>{selectedSymbol}</span>
                </div>
                {trades.length === 0 ? (
                  <p className="placeholder">아직 공유할 체결 클립이 없습니다. 샘플 체결을 먼저 넣어주세요.</p>
                ) : (
                  <ul className="news-list">
                    {trades.slice(0, 6).map((trade) => (
                      <li key={`clip-${trade.tradeId}-${trade.seq}`}>
                        {new Date(trade.ts).toLocaleTimeString("ko-KR", { hour12: false })} ·{" "}
                        {formatPrice(trade.price)} · {formatQty(trade.qty)}
                      </li>
                    ))}
                  </ul>
                )}
              </article>
            </section>
            <section className="terminal-grid">
              {renderMarketPanel("Trending Markets", "select symbol")}
              {renderOrderbookPanel()}
            </section>
          </>
        );
      case "/assets":
        return renderAssetsPage();
      case "/login":
        return renderAuthPage("login");
      case "/signup":
        return renderAuthPage("signup");
      case "/":
      default:
        return (
          <>
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
                  <button type="button" onClick={() => handleNavClick("/trade")}>
                    Start Trading
                  </button>
                </div>
              </article>

              <div className="hero-right">
                {renderMarketPanel()}
                {renderSystemFeedPanel()}
              </div>
            </section>

            <section className="terminal-grid">
              {renderTickerPanel()}
              {renderTradesPanel()}
              {renderOrderPanel()}
              {renderOrderbookPanel()}
            </section>
          </>
        );
    }
  };

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand" role="button" tabIndex={0} onClick={() => handleNavClick("/")} onKeyDown={handleBrandKeyDown}>
          <span className="brand-mark" />
          <span className="brand-text">QUANTA EXCHANGE</span>
        </div>
        <nav className="nav-list">
          {NAV_ITEMS.map((item) => (
            <button
              key={item.label}
              className={`nav-item ${currentPath === item.path ? "active" : ""}`}
              type="button"
              onClick={() => handleNavClick(item.path)}
            >
              {item.label}
            </button>
          ))}
        </nav>
        <div className="top-actions">
          {session ? (
            <>
              <span className="session-chip">{session.user.email}</span>
              <button type="button" className="btn-ghost" onClick={() => handleNavClick("/assets")}>
                My Assets
              </button>
              <button type="button" className="btn-primary" onClick={handleLogout}>
                Log Out
              </button>
            </>
          ) : (
            <>
              <button
                type="button"
                className="btn-ghost"
                onClick={() => {
                  setAuthMessage("");
                  handleNavClick("/login");
                }}
              >
                Log In
              </button>
              <button
                type="button"
                className="btn-primary"
                onClick={() => {
                  setAuthMessage("");
                  handleNavClick("/signup");
                }}
              >
                Sign Up
              </button>
            </>
          )}
        </div>
      </header>

      <main className="content">{renderRouteContent()}</main>
    </div>
  );
}
