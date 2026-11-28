import { PARAMS } from "../model/engine";
import { pct, usd } from "../model/format";

const SCALE = 0.12; // the meter reads 0–12% behind

/** How far a curator is behind its benchmark, with the breaker (5%) and bond-used-up (10%) lines. */
export function BehindMeter({ behind, frozen, idle }: { behind: number; frozen: boolean; idle: boolean }) {
  const fill = Math.min(behind, SCALE) / SCALE;
  const tone = frozen ? "frozen" : behind >= PARAMS.breaker * 0.6 ? "warning" : "steady";
  const at = (f: number) => `${(f / SCALE) * 100}%`;
  return (
    <figure className="meter-wrap">
      <div
        className={`meter meter--${tone}`}
        role="meter"
        aria-label="Behind its benchmark"
        aria-valuemin={0}
        aria-valuemax={SCALE * 100}
        aria-valuenow={Number((behind * 100).toFixed(1))}
        aria-valuetext={`${pct(behind)} behind its benchmark. The breaker trips at 5%.`}
      >
        <div className="meter-fill" style={{ height: `${fill * 100}%` }} />
        <div className="meter-line meter-line--breaker" style={{ bottom: at(PARAMS.breaker) }} />
        <div className="meter-line meter-line--bond" style={{ bottom: at(0.1) }} />
      </div>
      <div className="meter-scale" aria-hidden="true">
        <span style={{ bottom: at(0.1) }}>Bond used up</span>
        <span style={{ bottom: at(PARAMS.breaker) }}>Breaker</span>
      </div>
      <figcaption className="reading">
        <span className="reading-value">{idle ? "–" : pct(behind)}</span>
        <span className="reading-label">behind benchmark</span>
      </figcaption>
    </figure>
  );
}

/** The bond left, against the bond posted. The last slash shows as a red band above it. */
export function BondMeter({ bond, bondStart, lastSlash }: { bond: number; bondStart: number; lastSlash: number }) {
  const left = bondStart > 0 ? bond / bondStart : 0;
  const slashed = bondStart > 0 ? Math.min(lastSlash, bondStart - bond) / bondStart : 0;
  return (
    <figure className="meter-wrap">
      <div
        className="meter meter--bond"
        role="meter"
        aria-label="Bond left"
        aria-valuemin={0}
        aria-valuemax={bondStart}
        aria-valuenow={Math.round(bond)}
        aria-valuetext={`${usd(bond)} of ${usd(bondStart)} bond left`}
      >
        <div className="meter-fill" style={{ height: `${left * 100}%` }} />
        {slashed > 0 && (
          <div className="meter-slash" style={{ bottom: `${left * 100}%`, height: `${slashed * 100}%` }} />
        )}
      </div>
      <figcaption className="reading">
        <span className="reading-value">{usd(bond)}</span>
        <span className="reading-label">bond of {usd(bondStart)}</span>
      </figcaption>
    </figure>
  );
}
