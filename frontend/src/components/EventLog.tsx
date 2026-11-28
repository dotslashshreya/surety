import { clock } from "../model/format";
import type { Sim } from "../model/types";

export function EventLog({ sim }: { sim: Sim }) {
  return (
    <section className="log" aria-labelledby="log-title">
      <h2 id="log-title">What happened</h2>
      <ol className="log-list" aria-live="polite">
        {sim.events.slice(0, 14).map((e) => (
          <li key={e.id} className={`log-item log-item--${e.tone}`}>
            <time className="log-time">{clock(sim.startMs, e.t)}</time>
            <p className="log-text">{e.text}</p>
          </li>
        ))}
      </ol>
    </section>
  );
}
