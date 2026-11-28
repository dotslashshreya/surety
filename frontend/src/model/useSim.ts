import { useEffect, useReducer } from "react";
import * as E from "./engine";
import type { Sim } from "./types";

export type Action =
  | { type: "tick"; dt: number }
  | { type: "shock" }
  | { type: "endEpoch" }
  | { type: "reset" }
  | { type: "connect" }
  | { type: "switchNetwork" }
  | { type: "receiveGas" }
  | { type: "faucet" }
  | { type: "deposit"; meth: number; musdc: number }
  | { type: "settle" }
  | { type: "claim" }
  | { type: "withdraw"; shares: number };

function reducer(state: Sim, a: Action): Sim {
  if (a.type === "reset") return E.createSim(Date.now());
  const s = structuredClone(state);
  switch (a.type) {
    case "tick":
      E.advance(s, a.dt);
      break;
    case "shock":
      E.priceShock(s);
      break;
    case "endEpoch":
      E.endEpoch(s);
      break;
    case "connect":
      E.connect(s);
      break;
    case "switchNetwork":
      E.switchNetwork(s);
      break;
    case "receiveGas":
      E.receiveGas(s);
      break;
    case "faucet":
      E.useFaucet(s);
      break;
    case "deposit":
      E.deposit(s, a.meth, a.musdc);
      break;
    case "settle":
      E.settleNow(s);
      break;
    case "claim":
      E.claim(s);
      break;
    case "withdraw":
      E.requestWithdraw(s, a.shares);
      break;
  }
  return s;
}

/** The simulated pool, running `speed` simulated seconds per real second. Replaced by chain reads in M7. */
export function useSim(speed: number) {
  const [sim, dispatch] = useReducer(reducer, undefined, () => E.createSim(Date.now()));
  useEffect(() => {
    const id = window.setInterval(() => dispatch({ type: "tick", dt: 0.25 * speed }), 250);
    return () => window.clearInterval(id);
  }, [speed]);
  return [sim, dispatch] as const;
}
