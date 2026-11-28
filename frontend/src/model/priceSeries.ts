import { twap } from "./lpmath";
import { PARAMS } from "./engine";
import type { Sim } from "./types";

export interface PricePoint {
  t: number;
  spot: number;
  avg: number; // the 5-minute TWAP the breaker reads
}

/** The spot price at time `t`: the last price set at or before it. */
export function spotAt(history: { t: number; p: number }[], t: number): number {
  let p = history[0].p;
  for (const h of history) {
    if (h.t > t) break;
    p = h.p;
  }
  return p;
}

/** Spot and the 5-minute average, sampled over the last `span` simulated seconds (or since the start). */
export function priceSeries(s: Sim, span = 1800, points = 90): PricePoint[] {
  const end = s.t;
  const start = Math.max(0, end - span);
  const out: PricePoint[] = [];
  for (let i = 0; i <= points; i++) {
    const t = end > start ? start + ((end - start) * i) / points : end;
    out.push({ t, spot: spotAt(s.history, t), avg: twap(s.history, t, PARAMS.twapWindow) });
  }
  return out;
}
