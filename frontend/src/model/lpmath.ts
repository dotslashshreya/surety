// Concentrated-liquidity maths, in plain numbers. These are the same formulas the hook uses
// (SqrtPriceMath / ScoreLib), so the gauges move the way the contracts will.
// Prices are token1 per token0 (mUSDC per mETH); values are in token1 (dollars).

export interface Tokens {
  x: number; // token0 (mETH)
  y: number; // token1 (mUSDC)
}

/** Token amounts held by liquidity `L` in the range [a, b] at price `p`. */
export function tokensAt(L: number, p: number, a: number, b: number): Tokens {
  const sp = Math.sqrt(p);
  const sa = Math.sqrt(a);
  const sb = Math.sqrt(b);
  if (p <= a) return { x: L * (1 / sa - 1 / sb), y: 0 };
  if (p >= b) return { x: 0, y: L * (sb - sa) };
  return { x: L * (1 / sp - 1 / sb), y: L * (sp - sa) };
}

/** Value at price `p` of liquidity `L` in [a, b]. */
export function positionValue(L: number, p: number, a: number, b: number): number {
  const { x, y } = tokensAt(L, p, a, b);
  return x * p + y;
}

/** The liquidity that makes a position in [a, b] worth `value` at price `p`. */
export function liquidityForValue(value: number, p: number, a: number, b: number): number {
  const perUnit = positionValue(1, p, a, b);
  return perUnit > 0 ? value / perUnit : 0;
}

/** A full-range position worth `v0` at `p0`, marked at `p1`, plus its fees: V0·√(P1/P0) + fees. */
export function benchmark(v0: number, p0: number, p1: number, fees = 0): number {
  return v0 * Math.sqrt(p1 / p0) + fees;
}

/** How far behind its benchmark a slice is, as a fraction (0.052 = 5.2% behind). Never negative. */
export function shortfall(value: number, bench: number): number {
  if (bench <= 0) return 0;
  return Math.max(0, 1 - value / bench);
}

/**
 * Capital efficiency of a range relative to full range, for fee accrual: 1 / (1 − (a/b)^¼).
 * A ±3% range earns roughly 33× the fees of full range per dollar while the price is inside it.
 */
export function concentration(a: number, b: number): number {
  return 1 / (1 - Math.pow(a / b, 0.25));
}

/** Time-weighted mean price over the last `window` seconds of a step-function history. */
export function twap(history: { t: number; p: number }[], now: number, window: number): number {
  if (history.length === 0) return 0;
  const start = Math.max(now - window, history[0].t);
  if (now <= start) return history[history.length - 1].p;
  let acc = 0;
  for (let i = 0; i < history.length; i++) {
    const from = Math.max(history[i].t, start);
    const to = i + 1 < history.length ? Math.min(history[i + 1].t, now) : now;
    if (to > from) acc += history[i].p * (to - from);
  }
  return acc / (now - start);
}
