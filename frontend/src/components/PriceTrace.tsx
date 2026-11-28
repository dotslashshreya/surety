import { usd } from "../model/format";
import { priceSeries } from "../model/priceSeries";
import type { Sim } from "../model/types";

const W = 200;
const H = 40;

/** Spot and the 5-minute average the breaker reads, over the last 30 simulated minutes. */
export function PriceTrace({ sim }: { sim: Sim }) {
  const series = priceSeries(sim, 1800, 90);
  const values = series.flatMap((p) => [p.spot, p.avg]);
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const pad = Math.max((hi - lo) * 0.12, hi * 0.002);
  const yMin = lo - pad;
  const yMax = hi + pad;
  const t0 = series[0].t;
  const span = series[series.length - 1].t - t0 || 1;
  const x = (t: number) => ((t - t0) / span) * W;
  const y = (p: number) => H - ((p - yMin) / (yMax - yMin)) * H;
  const path = (key: "spot" | "avg") =>
    series.map((p, i) => `${i === 0 ? "M" : "L"}${x(p.t).toFixed(1)},${y(p[key]).toFixed(1)}`).join(" ");
  const avgNow = series[series.length - 1].avg;

  return (
    <span className="trace">
      <svg
        className="trace-chart"
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        role="img"
        aria-label={`Price ${usd(sim.price)}; 5-minute average ${usd(avgNow)}.`}
      >
        <path className="trace-avg" d={path("avg")} />
        <path className="trace-spot" d={path("spot")} />
      </svg>
      <span className="trace-legend" aria-hidden="true">
        <span className="key key--spot">Price</span>
        <span className="key key--avg">5-minute average {usd(avgNow)}</span>
      </span>
    </span>
  );
}
