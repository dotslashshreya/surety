import { describe, expect, it } from "vitest";
import * as E from "./engine";
import { priceSeries, spotAt } from "./priceSeries";
import { easeOut, tween } from "./tween";

describe("the bond count-down", () => {
  it("starts at the old value, ends exactly at the new one, and only moves one way", () => {
    expect(tween(9000, 4940, 0, 900)).toBe(9000);
    expect(tween(9000, 4940, 900, 900)).toBe(4940);
    expect(tween(9000, 4940, 5000, 900)).toBe(4940);
    let prev = 9000;
    for (let ms = 0; ms <= 900; ms += 30) {
      const v = tween(9000, 4940, ms, 900);
      expect(v).toBeLessThanOrEqual(prev);
      prev = v;
    }
  });

  it("does most of its movement early, like a strong ease-out", () => {
    expect(easeOut(0)).toBe(0);
    expect(easeOut(1)).toBe(1);
    expect(easeOut(0.3)).toBeGreaterThan(0.8);
  });
});

describe("the header price line", () => {
  it("shows spot dropping at once and the 5-minute average catching up over 5 minutes", () => {
    const s = E.createSim(0);
    E.advance(s, 600);
    const shockAt = s.t;
    E.priceShock(s); // 3,000 → 2,640
    E.advance(s, 600);
    const series = priceSeries(s, 1200, 120);

    const at = (t: number) => series.reduce((a, b) => (Math.abs(b.t - t) < Math.abs(a.t - t) ? b : a));
    expect(at(shockAt - 60).spot).toBe(3000);
    expect(at(shockAt + 10).spot).toBe(2640);
    const halfway = at(shockAt + 150).avg;
    expect(halfway).toBeLessThan(3000);
    expect(halfway).toBeGreaterThan(2640);
    expect(at(shockAt + 400).avg).toBeCloseTo(2640, 0);
  });

  it("starts from the beginning when the pool is younger than the span", () => {
    const s = E.createSim(0);
    E.advance(s, 60);
    const series = priceSeries(s, 1800, 10);
    expect(series[0].t).toBe(0);
    expect(series[series.length - 1].t).toBeCloseTo(60, 6);
    expect(series.every((p) => p.spot === 3000 && Math.abs(p.avg - 3000) < 1e-9)).toBe(true);
  });

  it("reads the last price set at or before a time", () => {
    const h = [
      { t: 0, p: 10 },
      { t: 5, p: 20 },
    ];
    expect(spotAt(h, 4.9)).toBe(10);
    expect(spotAt(h, 5)).toBe(20);
  });
});
