import { describe, expect, it } from "vitest";
import { benchmark, concentration, liquidityForValue, positionValue, shortfall, tokensAt, twap } from "./lpmath";

describe("liquidity maths", () => {
  it("values a position as token0 × price + token1", () => {
    const L = 1000;
    for (const p of [2500, 3000, 3100, 5000]) {
      const { x, y } = tokensAt(L, p, 2900, 3100);
      expect(positionValue(L, p, 2900, 3100)).toBeCloseTo(x * p + y, 6);
    }
  });

  it("round-trips value → liquidity → value", () => {
    const L = liquidityForValue(90_000, 3000, 2910, 3090);
    expect(positionValue(L, 3000, 2910, 3090)).toBeCloseTo(90_000, 6);
  });

  it("a near-full-range position tracks the benchmark V0·√(P1/P0)", () => {
    const L = liquidityForValue(100_000, 3000, 1e-6, 1e12);
    for (const p1 of [1500, 2640, 3000, 4500]) {
      expect(positionValue(L, p1, 1e-6, 1e12) / benchmark(100_000, 3000, p1)).toBeCloseTo(1, 3);
    }
  });

  it("after a 12% fall, a narrow range falls further behind than a wide one", () => {
    const p0 = 3000;
    const p1 = 2640;
    const narrow = liquidityForValue(90_000, p0, 2910, 3090);
    const wide = liquidityForValue(90_000, p0, 2200, 4100);
    const b = benchmark(90_000, p0, p1);
    const sNarrow = shortfall(positionValue(narrow, p1, 2910, 3090), b);
    const sWide = shortfall(positionValue(wide, p1, 2200, 4100), b);
    expect(sNarrow).toBeGreaterThan(0.05); // past the breaker
    expect(sWide).toBeLessThan(0.02);
    expect(sNarrow).toBeGreaterThan(sWide);
  });

  it("shortfall is never negative", () => {
    expect(shortfall(110, 100)).toBe(0);
    expect(shortfall(95, 100)).toBeCloseTo(0.05);
  });

  it("a narrow range is far more capital-efficient", () => {
    expect(concentration(2910, 3090)).toBeGreaterThan(30);
    expect(concentration(2200, 4100)).toBeLessThan(10);
  });

  it("time-weights the price over the window", () => {
    const h = [
      { t: 0, p: 100 },
      { t: 100, p: 200 },
    ];
    expect(twap(h, 200, 200)).toBeCloseTo(150);
    expect(twap(h, 200, 100)).toBeCloseTo(200);
    expect(twap(h, 150, 100)).toBeCloseTo(150);
  });
});
