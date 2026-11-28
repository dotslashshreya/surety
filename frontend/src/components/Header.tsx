import { epochEnded, nav, sharePrice } from "../model/engine";
import { clock, countdown, usd } from "../model/format";
import type { Sim } from "../model/types";
import { PriceTrace } from "./PriceTrace";

export function Header({ sim, speed }: { sim: Sim; speed: number }) {
  const end = sim.epoch.start + sim.epoch.length;
  const ended = epochEnded(sim) || sim.scored;
  return (
    <header className="masthead">
      <div className="brand">
        <p className="wordmark">Surety</p>
        <p className="pitch">The first LP manager who pays you back when they lose.</p>
      </div>
      <dl className="readouts">
        <div className="price-readout">
          <dt>mETH price</dt>
          <dd>
            {usd(sim.price)}
            <PriceTrace sim={sim} />
          </dd>
        </div>
        <div>
          <dt>Epoch {sim.scored ? sim.epoch.id - 1 : sim.epoch.id}</dt>
          <dd>
            {ended ? (
              <>Ended, settling</>
            ) : (
              <>
                Ends {clock(sim.startMs, end)} <span className="muted">in {countdown(end - sim.t)}</span>
              </>
            )}
          </dd>
        </div>
        <div>
          <dt>Share price</dt>
          <dd>${sharePrice(sim).toFixed(4)}</dd>
        </div>
        <div>
          <dt>In the vault</dt>
          <dd>{usd(nav(sim))}</dd>
        </div>
      </dl>
      <p className="preview-note">
        Preview with simulated data, running at {speed}× speed. The live version reads the pool on Unichain Sepolia.
      </p>
    </header>
  );
}
