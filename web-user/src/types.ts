export type WsMessage<T = Record<string, unknown>> = {
  type: string;
  channel?: string;
  symbol: string;
  seq: number;
  ts: number;
  data: T;
};

export type RawTickerData = {
  lastPrice?: string;
  high24h?: string;
  low24h?: string;
  volume24h?: string;
  quoteVolume24h?: string;
};

export type TickerResponse = {
  symbol: string;
  ticker: Partial<WsMessage<RawTickerData>> | Record<string, never>;
};

export type TradesResponse = {
  symbol: string;
  trades: WsMessage<Record<string, unknown>>[];
};

export type CandlesResponse = {
  symbol: string;
  candles: WsMessage<Record<string, unknown>>[];
};

export type OrderbookResponse = {
  symbol: string;
  depth: number;
  bids: unknown[];
  asks: unknown[];
};

export type OrderRequest = {
  symbol: string;
  side: "BUY" | "SELL";
  type: "LIMIT" | "MARKET";
  price: string;
  qty: string;
  timeInForce: "GTC" | "IOC" | "FOK";
};

export type OrderResponse = {
  orderId: string;
  status: string;
  symbol: string;
  seq: number;
  acceptedAt?: number;
  canceledAt?: number;
  rejectCode?: string;
  correlationId?: string;
};

export type AuthUser = {
  userId: string;
  email: string;
};

export type AuthSessionResponse = {
  user: AuthUser;
  sessionToken: string;
  expiresAt: number;
};

export type AuthMeResponse = {
  user: AuthUser;
};

export type BalanceItem = {
  currency: string;
  available: number;
  hold: number;
  total: number;
  priceKrw?: number;
  valueKrw?: number;
};

export type BalancesResponse = {
  userId: string;
  balances: BalanceItem[];
};

export type PortfolioResponse = {
  userId: string;
  assets: BalanceItem[];
  totalAssetValue: number;
  updatedAt: number;
};
