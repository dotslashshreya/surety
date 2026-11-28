import { anchorValue, curatorValue, liveShortfall, nav } from "../model/engine";
import { pct, usd } from "../model/format";
import type { Curator, Sim } from "../model/types";
import { BehindMeter, BondMeter } from "./Meters";

function statusText(c: Curator): string {
  if (c.status === "frozen") return "Frozen until the epoch ends";
  if (c.status === "rearm") return c.pendingRange ? "Rejoins at the next settlement" : "Waiting for a new range";
  return "Live";
}

function lastEpoch(c: Curator): string | null {
  if (c.lastSlash > 0) return `Slashed ${usd(c.lastSlash)} last epoch`;
  if (c.lastFee > 0) return `Earned a ${usd(c.lastFee)} fee last epoch`;
  return null;
}

function Bay({ sim, c, total }: { sim: Sim; c: Curator; total: number }) {
  const value = curatorValue(c, sim.price);
  const behind = c.status === "rearm" ? 0 : liveShortfall(sim, c);
  const range = c.pendingRange ?? { lo: c.lo, hi: c.hi };
  const note = lastEpoch(c);
  return (
    <article className={`bay bay--${c.status}`} aria-labelledby={`bay-${c.id}`}>
      <header className="bay-head">
        <h3 id={`bay-${c.id}`} className="bay-name">
          {c.name}
        </h3>
        <p className="bay-strategy">{c.strategy}</p>
        <p className={`status status--${c.status}`}>{statusText(c)}</p>
      </header>
      <div className="meters">
        <BehindMeter behind={behind} frozen={c.status === "frozen"} idle={c.status === "rearm"} />
        <BondMeter bond={c.bond} bondStart={c.bondStart} lastSlash={c.lastSlash} />
      </div>
      <dl className="facts">
        <div>
          <dt>Manages</dt>
          <dd>
            {value < 1 ? (
              <span className="muted">Nothing yet</span>
            ) : (
              <>
                {usd(value)} <span className="muted">({pct(total > 0 ? value / total : 0, 0)} of the vault)</span>
              </>
            )}
          </dd>
        </div>
        <div>
          <dt>Range</dt>
          <dd>
            {usd(range.lo)} to {usd(range.hi)}
          </dd>
        </div>
        {note && (
          <div>
            <dt>Last epoch</dt>
            <dd className={c.lastSlash > 0 ? "tone-slash" : "tone-gain"}>{note}</dd>
          </div>
        )}
      </dl>
    </article>
  );
}

export function CuratorPanel({ sim }: { sim: Sim }) {
  const total = nav(sim);
  const anchor = anchorValue(sim, sim.price);
  return (
    <section className="instrument" aria-labelledby="curators-title">
      <header className="instrument-head">
        <h2 id="curators-title">Curators</h2>
        <p>
          Each curator is measured against a passive full-range position of the same size. Fall 5% behind and its
          liquidity is pulled out of the pool. When the epoch ends, the shortfall is paid from its bond.
        </p>
      </header>
      <div className="bays">
        {sim.curators.map((c) => (
          <Bay key={c.id} sim={sim} c={c} total={total} />
        ))}
      </div>
      <p className="anchor-strip">
        <strong>Full-range anchor:</strong> {usd(anchor)}, {pct(total > 0 ? anchor / total : 0, 0)} of the vault. It is
        never frozen, so the pool always has liquidity.
      </p>
    </section>
  );
}
