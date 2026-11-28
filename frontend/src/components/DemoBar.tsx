import type { Dispatch } from "react";
import type { Action } from "../model/useSim";

/** Local chain only: makes every beat of the video happen on cue. Hidden on testnet. */
export function DemoBar({ dispatch }: { dispatch: Dispatch<Action> }) {
  return (
    <section className="demobar" aria-labelledby="demo-title">
      <h2 id="demo-title">Demo controls</h2>
      <p className="muted">Local chain only. Hidden on testnet.</p>
      <div className="demobar-actions">
        <button type="button" className="btn btn--warn" onClick={() => dispatch({ type: "shock" })}>
          Price shock (−12%)
        </button>
        <button type="button" className="btn" onClick={() => dispatch({ type: "endEpoch" })}>
          End epoch
        </button>
        <button type="button" className="btn btn--quiet" onClick={() => dispatch({ type: "reset" })}>
          Reset
        </button>
      </div>
    </section>
  );
}
