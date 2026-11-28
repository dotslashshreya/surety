const usd0 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
const usd2 = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });
const num = new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 });

/** $412,300 for large amounts, $12.40 for small ones. */
export function usd(n: number): string {
  return Math.abs(n) >= 100 ? usd0.format(n) : usd2.format(n);
}

/** 0.0523 → "5.2%". */
export function pct(f: number, digits = 1): string {
  return `${(f * 100).toFixed(digits)}%`;
}

export function amount(n: number): string {
  return num.format(n);
}

/** Wall-clock time for a simulation second, e.g. "14:32". */
export function clock(startMs: number, t: number): string {
  return new Date(startMs + t * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/** Seconds as "12:03" or "1:02:03". */
export function countdown(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
  return `${h > 0 ? `${h}:` : ""}${mm}:${String(r).padStart(2, "0")}`;
}
