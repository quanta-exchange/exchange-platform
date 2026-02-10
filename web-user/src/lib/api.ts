import type {
  CandlesResponse,
  OrderRequest,
  OrderResponse,
  OrderbookResponse,
  TickerResponse,
  TradesResponse,
} from "../types";

const API_BASE_URL = (import.meta.env.VITE_API_BASE_URL ?? "").replace(/\/$/, "");
const WS_URL = import.meta.env.VITE_WS_URL;

function toUrl(path: string): string {
  if (!API_BASE_URL) {
    return path;
  }
  return `${API_BASE_URL}${path.startsWith("/") ? "" : "/"}${path}`;
}

function idempotencyKey(prefix: string): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return `${prefix}-${crypto.randomUUID()}`;
  }
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1_000_000)}`;
}

async function readErrorMessage(response: Response): Promise<string> {
  try {
    const payload = (await response.json()) as { error?: string };
    if (typeof payload.error === "string" && payload.error.trim() !== "") {
      return payload.error;
    }
  } catch {
    // Keep fallback.
  }
  return response.statusText || `HTTP ${response.status}`;
}

async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(toUrl(path), {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });

  if (!response.ok) {
    throw new Error(await readErrorMessage(response));
  }
  return (await response.json()) as T;
}

export function getWsUrl(): string {
  if (typeof WS_URL === "string" && WS_URL.trim() !== "") {
    return WS_URL;
  }

  if (API_BASE_URL.startsWith("http://") || API_BASE_URL.startsWith("https://")) {
    const url = new URL(API_BASE_URL);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.pathname = "/ws";
    url.search = "";
    url.hash = "";
    return url.toString();
  }

  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}/ws`;
}

export async function fetchTicker(symbol: string): Promise<TickerResponse> {
  return requestJson<TickerResponse>(`/v1/markets/${symbol}/ticker`);
}

export async function fetchTrades(symbol: string, limit = 30): Promise<TradesResponse> {
  return requestJson<TradesResponse>(`/v1/markets/${symbol}/trades?limit=${limit}`);
}

export async function fetchCandles(symbol: string): Promise<CandlesResponse> {
  return requestJson<CandlesResponse>(`/v1/markets/${symbol}/candles?interval=1m`);
}

export async function fetchOrderbook(symbol: string, depth = 20): Promise<OrderbookResponse> {
  return requestJson<OrderbookResponse>(`/v1/markets/${symbol}/orderbook?depth=${depth}`);
}

export async function createOrder(payload: OrderRequest): Promise<OrderResponse> {
  return requestJson<OrderResponse>("/v1/orders", {
    method: "POST",
    headers: {
      "Idempotency-Key": idempotencyKey("order"),
    },
    body: JSON.stringify(payload),
  });
}

export async function cancelOrder(orderId: string): Promise<OrderResponse> {
  return requestJson<OrderResponse>(`/v1/orders/${orderId}`, {
    method: "DELETE",
    headers: {
      "Idempotency-Key": idempotencyKey("cancel"),
    },
  });
}

export async function fetchOrder(orderId: string): Promise<OrderResponse> {
  return requestJson<OrderResponse>(`/v1/orders/${orderId}`);
}

export async function postSmokeTrade(symbol: string, price: string, qty: string): Promise<void> {
  await requestJson<{ status: string; seq: number }>("/v1/smoke/trades", {
    method: "POST",
    body: JSON.stringify({
      tradeId: idempotencyKey("ui-trade"),
      symbol,
      price,
      qty,
    }),
  });
}
