import { describe, expect, it } from "vitest";
import * as E from "./engine";
import { depositorView } from "./depositor";

describe("the depositor panel", () => {
  it("walks a judge from an empty wallet to holding shares, one step at a time", () => {
    const s = E.createSim(0);
    expect(depositorView(s).step).toBe("connect");
    E.connect(s);
    expect(depositorView(s).step).toBe("network");
    E.switchNetwork(s);
    expect(depositorView(s).step).toBe("gas");
    E.receiveGas(s);
    expect(depositorView(s).step).toBe("tokens");
    E.useFaucet(s);
    expect(depositorView(s).step).toBe("deposit");
    expect(depositorView(s).faucetWait).toBe(E.PARAMS.faucet.cooldown);

    E.deposit(s, 1, 3000);
    const queued = depositorView(s);
    expect(queued.step).toBe("shares");
    expect(queued.joinsAt).toBe(s.epoch.start + s.epoch.length);
    expect(queued.canSettle).toBe(false);

    E.advance(s, E.PARAMS.epochLength + 1);
    expect(depositorView(s).canSettle).toBe(true);
    E.settleNow(s);
    const settled = depositorView(s);
    expect(settled.hasClaim).toBe(true);
    E.claim(s);
    expect(depositorView(s).done.shares).toBe(true);
  });

  it("explains a blocked settlement instead of offering a button that would fail", () => {
    const s = E.createSim(0);
    E.advance(s, E.PARAMS.epochLength + 1);
    E.priceShock(s);
    const v = depositorView(s);
    expect(v.canSettle).toBe(true);
    expect(v.settleBlockedFor).toBeGreaterThan(0);
  });

  it("a deposit made after the epoch was scored joins at the end of the next epoch", () => {
    const s = E.createSim(0);
    E.connect(s);
    E.switchNetwork(s);
    E.receiveGas(s);
    E.useFaucet(s);
    E.advance(s, E.PARAMS.epochLength + 1); // scored, not yet settled
    E.deposit(s, 1, 0);
    expect(depositorView(s).joinsAt).toBe(s.epoch.start + s.epoch.length);
  });
});
