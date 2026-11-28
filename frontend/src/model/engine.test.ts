import { describe, expect, it } from "vitest";
import {
  PARAMS,
  advance,
  anchorValue,
  claim,
  connect,
  createSim,
  curatorValue,
  deposit,
  endEpoch,
  liveShortfall,
  nav,
  priceShock,
  receiveGas,
  requestWithdraw,
  settleNow,
  sharePrice,
  switchNetwork,
  useFaucet,
} from "./engine";
import type { Sim } from "./types";

const careful = (s: Sim) => s.curators[0];
const reckless = (s: Sim) => s.curators[1];

describe("the pool at start", () => {
  it("holds $200,000 at a share price of 1", () => {
    const s = createSim(0);
    expect(nav(s)).toBeCloseTo(200_000, 0);
    expect(sharePrice(s)).toBeCloseTo(1, 6);
    expect(anchorValue(s, s.price) / nav(s)).toBeCloseTo(0.1, 6);
  });
});

describe("the breaker", () => {
  it("does not freeze on the shock alone: the 5-minute TWAP has to catch up", () => {
    const s = createSim(0);
    advance(s, 60);
    priceShock(s);
    advance(s, 12);
    expect(reckless(s).status).toBe("live");
    expect(liveShortfall(s, reckless(s))).toBeLessThan(PARAMS.breaker);
  });

  it("freezes only the reckless curator once the TWAP has caught up, and never touches a bond", () => {
    const s = createSim(0);
    advance(s, 60);
    priceShock(s);
    advance(s, 360);
    expect(reckless(s).status).toBe("frozen");
    expect(reckless(s).L).toBe(0);
    expect(reckless(s).bond).toBe(reckless(s).bondStart);
    expect(careful(s).status).toBe("live");
    expect(s.events.some((e) => e.tone === "freeze" && e.text.startsWith("Reckless frozen"))).toBe(true);
  });
});

describe("the end of an epoch", () => {
  it("slashes the frozen curator, returns its slice and moves nothing to it", () => {
    const s = createSim(0);
    advance(s, 60);
    priceShock(s);
    advance(s, 360);
    const carefulBefore = curatorValue(careful(s), s.price);
    endEpoch(s);
    const r = reckless(s);
    expect(r.lastSlash).toBeGreaterThan(0);
    expect(r.lastSlash).toBeLessThanOrEqual(r.bondStart);
    expect(r.bond).toBeCloseTo(r.bondStart - r.lastSlash, 6);
    expect(r.status).toBe("rearm");
    expect(r.pendingRange).toBeDefined();
    expect(curatorValue(r, s.price)).toBe(0);
    expect(curatorValue(careful(s), s.price)).toBeGreaterThan(carefulBefore);
    expect(s.events.some((e) => e.tone === "slash" && e.text.startsWith("Reckless slashed"))).toBe(true);
  });

  it("brings a re-armed curator back at the following settlement; it gets capital once new money arrives", () => {
    const s = createSim(0);
    advance(s, 60);
    priceShock(s);
    advance(s, 360);
    endEpoch(s);
    endEpoch(s);
    expect(reckless(s).status).toBe("live");
    // Careful's cap absorbed the returned slice, so nothing above the anchor's 10% is free yet.
    expect(curatorValue(reckless(s), s.price)).toBeLessThan(1_000);

    connect(s);
    switchNetwork(s);
    receiveGas(s);
    useFaucet(s);
    deposit(s, 1, 3000);
    endEpoch(s);
    expect(curatorValue(reckless(s), s.price)).toBeGreaterThan(1_000);
  });

  it("in a quiet market pays both curators a performance fee and slashes nobody", () => {
    const s = createSim(0);
    endEpoch(s);
    expect(careful(s).lastSlash).toBe(0);
    expect(reckless(s).lastSlash).toBe(0);
    expect(careful(s).lastFee).toBeGreaterThan(0);
    expect(reckless(s).lastFee).toBeGreaterThan(careful(s).lastFee);
  });

  it("keeps every slice within 10 × its bond and at least 10% in the anchor", () => {
    const s = createSim(0);
    advance(s, 60);
    priceShock(s);
    advance(s, 360);
    endEpoch(s);
    for (const c of s.curators) {
      expect(curatorValue(c, s.price)).toBeLessThanOrEqual(c.bond * PARAMS.bondMultiple + 1e-6);
    }
    expect(anchorValue(s, s.price)).toBeGreaterThanOrEqual(nav(s) * PARAMS.anchorShare - 1e-6);
  });

  it("refuses to settle while spot is far from the 5-minute TWAP", () => {
    const s = createSim(0);
    advance(s, PARAMS.epochLength + 1); // the epoch is scored
    priceShock(s);
    settleNow(s);
    expect(s.scored).toBe(true);
  });
});

describe("your deposit", () => {
  function funded(): Sim {
    const s = createSim(0);
    connect(s);
    switchNetwork(s);
    receiveGas(s);
    useFaucet(s);
    return s;
  }

  it("the faucet gives 1 mETH and 3,000 mUSDC, once a day", () => {
    const s = funded();
    expect(s.you.meth).toBe(1);
    expect(s.you.musdc).toBe(3000);
    useFaucet(s);
    expect(s.you.meth).toBe(1);
  });

  it("joins at settlement, at the share price, and can be withdrawn again", () => {
    const s = funded();
    deposit(s, 1, 3000);
    expect(s.you.pendingDeposit).toBeDefined();
    settleNow(s); // too early: nothing happens
    expect(s.you.claimableShares).toBe(0);

    endEpoch(s);
    expect(s.you.pendingDeposit).toBeUndefined();
    const price = sharePrice(s);
    expect(s.you.claimableShares * price).toBeCloseTo(6000, -1);
    claim(s);
    expect(s.you.shares).toBeGreaterThan(0);

    requestWithdraw(s, s.you.shares);
    endEpoch(s);
    claim(s);
    // Back in full, plus a little trading-fee income from two epochs in the vault.
    const back = s.you.meth * s.price + s.you.musdc;
    expect(back).toBeGreaterThan(5990);
    expect(back).toBeLessThan(6060);
  });

  it("a deposit made after the epoch was scored waits for the next settlement", () => {
    const s = funded();
    advance(s, PARAMS.epochLength + 1); // scored, but the keeper hasn't settled yet
    deposit(s, 1, 3000);
    endEpoch(s); // settles the scored epoch
    expect(s.you.pendingDeposit).toBeDefined();
    endEpoch(s);
    expect(s.you.pendingDeposit).toBeUndefined();
  });
});
