const priceFormatter = new Intl.NumberFormat("ko-KR");
const compactFormatter = new Intl.NumberFormat("en-US", {
  notation: "compact",
  maximumFractionDigits: 2,
});
const qtyFormatter = new Intl.NumberFormat("ko-KR", {
  maximumFractionDigits: 4,
});

export function asNumber(value: unknown): number {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : 0;
  }
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

export function formatPrice(value: number): string {
  return `₩${priceFormatter.format(Math.round(value))}`;
}

export function formatCount(value: number): string {
  return priceFormatter.format(Math.max(0, Math.round(value)));
}

export function formatCompact(value: number): string {
  return compactFormatter.format(value);
}

export function formatQty(value: number): string {
  return qtyFormatter.format(value);
}

export function formatSignedPercent(value: number): string {
  const sign = value > 0 ? "+" : "";
  return `${sign}${value.toFixed(2)}%`;
}
