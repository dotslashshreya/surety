// A simulation of one Surety pool that follows the contract's rules: the breaker, scoring at the epoch-long
// average price, slashing, the performance fee, the worst-to-best shift, the k × bond cap and the 10% anchor.
// It drives the dashboard until the frontend is wired to the chain in M7. Functions mutate a draft; the reducer
// clones state first.

import { benchmark, concentration, liquidityForValue, positionValue, shortfall, tokensAt, twap } from "./lpmath";
import { amount, pct, usd } from "./format";
import type { Curator, Sim, Tone } from "./types";

export const PARAMS = {
  epochLength: 1800, // 30 minutes, as in the local demo
  breaker: 0.05,
  twapWindow: 300,
  checkEvery: 12,
  bondMultiple: 10,
  perfFee: 0.2,
  shift: 0.25,
  anchorShare: 0.1,
  rewardShare: 0.05,
  maxReward: 500,
  spotBand: 0.05, // settle() needs spot within about 5% (500 ticks) of the 5-minute TWAP
  feeRate: 2e-8, // fees per second per dollar of full-range liquidity: a ±3% range earns about 0.24% per epoch
  keeperDelay: 90,
  faucet: { meth: 1, musdc: 3000, cooldown: 86_400 },
} as const;

// ---------------------------------------------------------------- valuation

export function curatorValue(c: Curator, p: number): number {
  if (c.frozen) return c.frozen.x * p + c.frozen.y + c.fees;
  if (c.L <= 0) return c.fees;
  return positionValue(c.L, p, c.lo, c.hi) + c.fees;
}

export function anchorValue(s: Sim, p: number): number {
  return 2 * s.anchorL * Math.sqrt(p);
}

export function nav(s: Sim, p = s.price): number {
  return s.curators.reduce((acc, c) => acc + curatorValue(c, p), 0) + anchorValue(s, p) + s.reserve;
}

export function sharePrice(s: Sim): number {
  return s.supply > 0 ? nav(s) / s.supply : 1;
}

export function shortTwap(s: Sim): number {
  return twap(s.history, s.t, PARAMS.twapWindow);
}

/** How far behind its benchmark a curator is right now, measured at the 5-minute TWAP, as the breaker does. */
export function liveShortfall(s: Sim, c: Curator): number {
  if (c.v0 <= 0) return 0;
  const p = shortTwap(s);
  return shortfall(curatorValue(c, p), benchmark(c.v0, s.mark, p, c.benchFees));
}

export function epochEnded(s: Sim): boolean {
  return s.t >= s.epoch.start + s.epoch.length;
}

export function settleAllowed(s: Sim): boolean {
  return Math.abs(s.price / shortTwap(s) - 1) <= PARAMS.spotBand;
}

// ---------------------------------------------------------------- setup

function makeCurator(id: string, name: string, strategy: string, lo: number, hi: number, capital: number, bond: number, p: number): Curator {
  return {
    id,
    name,
    strategy,
    lo,
    hi,
    L: liquidityForValue(capital, p, lo, hi),
    v0: capital,
    fees: 0,
    benchFees: 0,
    bond,
    bondStart: bond,
    status: "live",
    lastSlash: 0,
    lastFee: 0,
    lastExcess: 0,
  };
}

/** A fresh pool: $200,000 from depositors at 3,000 mUSDC per mETH, two curators, 10% in the anchor. */
export function createSim(startMs: number): Sim {
  const p = 3000;
  const s: Sim = {
    t: 0,
    startMs,
    price: p,
    history: [{ t: 0, p }],
    epoch: { id: 1, start: 0, length: PARAMS.epochLength },
    mark: p,
    scored: false,
    scoredAt: 0,
    curators: [
      makeCurator("careful", "Careful", "Wide range, recentred when the price drifts", 2200, 4100, 90_000, 18_000, p),
      makeCurator("reckless", "Reckless", "Narrow range around the price, never rebalanced", 2910, 3090, 90_000, 9_000, p),
    ],
    anchorL: 20_000 / (2 * Math.sqrt(p)),
    reserve: 0,
    supply: 200_000,
    rewardPool: 0,
    lastCheck: 0,
    events: [],
    nextId: 1,
    you: {
      connected: false,
      rightNetwork: false,
      gas: 0,
      meth: 0,
      musdc: 0,
      shares: 0,
      faucetReadyAt: 0,
      claimableShares: 0,
      claimableMeth: 0,
      claimableMusdc: 0,
    },
  };
  emit(s, "info", "Epoch 1 started. Depositors put in $200,000; Careful and Reckless manage $90,000 each.");
  return s;
}

function emit(s: Sim, tone: Tone, text: string) {
  s.events.unshift({ id: s.nextId++, t: s.t, tone, text });
  if (s.events.length > 40) s.events.length = 40;
}

// ---------------------------------------------------------------- time

/** Let `dt` simulation seconds pass: fees accrue, the breaker checks, epochs end, the keeper settles. */
export function advance(s: Sim, dt: number) {
  let left = dt;
  while (left > 1e-9) {
    const d = Math.min(4, left);
    left -= d;
    s.t += d;
    accrueFees(s, d);
    if (s.t - s.lastCheck >= PARAMS.checkEvery) breakerCheck(s);
    if (!s.scored && epochEnded(s)) score(s);
    if (s.scored && s.t - s.scoredAt >= PARAMS.keeperDelay && settleAllowed(s)) settle(s, "keeper");
  }
}

function accrueFees(s: Sim, d: number) {
  for (const c of s.curators) {
    if (c.status === "live" && c.L > 0 && s.price >= c.lo && s.price <= c.hi) {
      c.fees += positionValue(c.L, s.price, c.lo, c.hi) * PARAMS.feeRate * concentration(c.lo, c.hi) * d;
    }
    if (c.status === "live" && c.v0 > 0) c.benchFees += c.v0 * PARAMS.feeRate * d;
  }
  s.reserve += anchorValue(s, s.price) * PARAMS.feeRate * d;
}

function breakerCheck(s: Sim) {
  s.lastCheck = s.t;
  for (const c of s.curators) {
    if (c.status !== "live" || c.L <= 0 || c.v0 <= 0) continue;
    const behind = liveShortfall(s, c);
    if (behind < PARAMS.breaker) continue;
    c.frozen = tokensAt(c.L, s.price, c.lo, c.hi); // liquidity comes out at the current price
    c.L = 0;
    c.status = "frozen";
    emit(s, "freeze", `${c.name} frozen: ${pct(behind)} behind its benchmark. Its liquidity is out of the pool until the epoch ends.`);
  }
}

// ---------------------------------------------------------------- epoch end

/** What the first swap after an epoch ends does: score every slice at the epoch's average price. */
export function score(s: Sim) {
  const end = s.epoch.start + s.epoch.length;
  const p1 = twap(s.history, end, s.epoch.length);
  const id = s.epoch.id;
  emit(s, "info", `Epoch ${id} ended at an average price of ${usd(p1)} per mETH.`);

  const ratios: { id: string; r: number }[] = [];
  for (const c of s.curators) {
    if (c.v0 <= 0) continue;
    const v1 = curatorValue(c, p1);
    const b = benchmark(c.v0, s.mark, p1, c.benchFees);
    const e = v1 - b;
    c.lastExcess = e;
    c.lastSlash = 0;
    c.lastFee = 0;
    if (e < 0) {
      const slash = Math.min(c.bond, -e);
      c.bond -= slash;
      c.lastSlash = slash;
      const reward = slash * PARAMS.rewardShare;
      s.rewardPool += reward;
      s.reserve += slash - reward;
      emit(s, "slash", `${c.name} slashed ${usd(slash)}: it finished ${pct(-e / b)} behind its benchmark. Depositors keep the money.`);
    } else if (e > 0) {
      const fee = e * PARAMS.perfFee;
      const n = nav(s, p1);
      if (n > fee && s.supply > 0) s.supply += (fee * s.supply) / (n - fee);
      c.lastFee = fee;
      emit(s, "gain", `${c.name} beat its benchmark by ${usd(e)} and earned a ${usd(fee)} performance fee.`);
    }
    if (c.status === "frozen") {
      s.reserve += curatorValue(c, p1);
      c.frozen = undefined;
      c.fees = 0;
      c.v0 = 0;
      c.status = "rearm";
      emit(s, "info", `${c.name}'s slice went back to depositors. It gets no capital until it picks a new range.`);
    } else {
      ratios.push({ id: c.id, r: e / c.v0 });
      const v1Now = curatorValue(c, s.price);
      c.fees = 0;
      c.benchFees = 0;
      c.L = liquidityForValue(v1Now, s.price, c.lo, c.hi);
      c.v0 = v1;
    }
  }

  ratios.sort((a, b) => a.r - b.r);
  s.shift = undefined;
  if (ratios.length >= 2) {
    const worst = ratios[0];
    const best = ratios[ratios.length - 1];
    if (worst.r < 0 && best.r - worst.r > 1e-6) s.shift = { from: worst.id, to: best.id };
  }

  s.mark = p1;
  s.epoch = { id: id + 1, start: s.t, length: s.epoch.length };
  s.scored = true;
  s.scoredAt = s.t;
}

/** settle(): reallocate, process queued deposits and withdrawals, rebuild the anchor, pay the caller. */
export function settle(s: Sim, by: "you" | "keeper") {
  if (!s.scored) return;
  const p = s.price;
  const settledEpoch = s.epoch.id - 1;
  const byId = (id: string) => s.curators.find((c) => c.id === id)!;
  const setCapital = (c: Curator, value: number) => {
    const fees = c.fees;
    c.L = liquidityForValue(Math.max(0, value - fees), p, c.lo, c.hi);
  };

  // A curator that re-armed after a freeze joins now.
  for (const c of s.curators) {
    if (c.status === "rearm" && c.pendingRange) {
      c.lo = c.pendingRange.lo;
      c.hi = c.pendingRange.hi;
      c.pendingRange = undefined;
      c.status = "live";
      c.L = 0;
      c.v0 = 0;
    }
  }

  // The anchor comes back into the reserve; from here everything is reserve bookkeeping.
  s.reserve += anchorValue(s, p);
  s.anchorL = 0;

  // Queued withdrawals, paid in kind and pro rata (approximated here as half in each token).
  const w = s.you.pendingWithdraw;
  if (w && w.batch < s.epoch.id) {
    const f = w.shares / s.supply;
    const out = nav(s, p) * f;
    for (const c of s.curators) setCapital(c, curatorValue(c, p) * (1 - f));
    s.reserve *= 1 - f;
    s.supply -= w.shares;
    s.you.claimableMeth += out / 2 / p;
    s.you.claimableMusdc += out / 2;
    s.you.pendingWithdraw = undefined;
    emit(s, "info", `Your withdrawal of ${amount(w.shares)} shares is ready to claim: ${usd(out)}.`);
  }

  // Queued deposits, priced at the 5-minute TWAP.
  const d = s.you.pendingDeposit;
  if (d && d.batch < s.epoch.id) {
    const px = shortTwap(s);
    const value = d.meth * px + d.musdc;
    const n = nav(s, px);
    const minted = s.supply > 0 && n > 0 ? (value * s.supply) / n : value;
    s.reserve += value;
    s.supply += minted;
    s.you.claimableShares += minted;
    s.you.pendingDeposit = undefined;
    emit(s, "info", `Your deposit of ${usd(value)} joined the vault: ${amount(Math.floor(minted))} shares to claim.`);
  }

  // Worst-to-best shift.
  if (s.shift) {
    const from = byId(s.shift.from);
    const to = byId(s.shift.to);
    if (from.status === "live" && to.status === "live") {
      const moved = curatorValue(from, p) * PARAMS.shift;
      setCapital(from, curatorValue(from, p) - moved);
      setCapital(to, curatorValue(to, p) + moved);
      emit(s, "info", `${usd(moved)} of capital moved from ${from.name} to ${to.name}.`);
    }
    s.shift = undefined;
  }

  // Cap every slice at k × bond.
  for (const c of s.curators) {
    if (c.status !== "live") continue;
    const v = curatorValue(c, p);
    const cap = c.bond * PARAMS.bondMultiple;
    if (v > cap) {
      setCapital(c, cap);
      s.reserve += v - cap;
    }
  }

  // Share out the reserve above the anchor's 10%, equally, within each slice's headroom.
  const live = s.curators.filter((c) => c.status === "live");
  const target = nav(s, p) * PARAMS.anchorShare;
  const free = s.reserve - target;
  if (free > 0 && live.length > 0) {
    const share = free / live.length;
    for (const c of live) {
      const v = curatorValue(c, p);
      const room = Math.max(0, c.bond * PARAMS.bondMultiple - v);
      const add = Math.min(share, room);
      setCapital(c, v + add);
      s.reserve -= add;
    }
  }

  // New starting values at the mark, and everything left in the reserve goes full range.
  for (const c of live) c.v0 = curatorValue(c, s.mark);
  s.anchorL = s.reserve / (2 * Math.sqrt(p));
  s.reserve = 0;

  const reward = Math.min(s.rewardPool, PARAMS.maxReward);
  s.rewardPool -= reward;
  if (by === "you") {
    s.you.musdc += reward;
    emit(s, "info", reward > 0 ? `You settled epoch ${settledEpoch} and earned a ${usd(reward)} reward.` : `You settled epoch ${settledEpoch}.`);
  } else {
    emit(s, "info", reward > 0 ? `The keeper settled epoch ${settledEpoch} and earned ${usd(reward)}.` : `The keeper settled epoch ${settledEpoch}.`);
  }
  s.scored = false;

  // The reckless bot re-arms right away with a fresh narrow range around the price.
  for (const c of s.curators) {
    if (c.status === "rearm" && !c.pendingRange) {
      c.pendingRange = { lo: Math.round(p * 0.97), hi: Math.round(p * 1.03) };
      emit(s, "info", `${c.name} picked a new range, ${usd(c.pendingRange.lo)} to ${usd(c.pendingRange.hi)}. It rejoins at the next settlement.`);
    }
  }
}

// ---------------------------------------------------------------- demo controls

export function priceShock(s: Sim, move = -0.12) {
  s.price = Math.round(s.price * (1 + move) * 100) / 100;
  s.history.push({ t: s.t, p: s.price });
  emit(s, "info", `Price shock: mETH ${move < 0 ? "fell" : "rose"} ${pct(Math.abs(move), 0)} to ${usd(s.price)}.`);
}

/** Fast-forward to the end of the epoch, hold until settle() is allowed, and let the keeper settle. */
export function endEpoch(s: Sim) {
  if (!s.scored) advance(s, Math.max(0, s.epoch.start + s.epoch.length - s.t) + 1);
  let guard = 0;
  while (s.scored && !settleAllowed(s) && guard++ < 40) advance(s, 30);
  if (s.scored) settle(s, "keeper");
}

// ---------------------------------------------------------------- your wallet (simulated until M7)

export function connect(s: Sim) {
  s.you.connected = true;
}

export function switchNetwork(s: Sim) {
  s.you.rightNetwork = true;
}

export function receiveGas(s: Sim) {
  s.you.gas = 0.05;
}

export function useFaucet(s: Sim) {
  if (s.t < s.you.faucetReadyAt || s.you.gas <= 0) return;
  s.you.meth += PARAMS.faucet.meth;
  s.you.musdc += PARAMS.faucet.musdc;
  s.you.faucetReadyAt = s.t + PARAMS.faucet.cooldown;
}

export function deposit(s: Sim, meth: number, musdc: number) {
  if (meth < 0 || musdc < 0 || meth + musdc <= 0) return;
  if (meth > s.you.meth + 1e-12 || musdc > s.you.musdc + 1e-9) return;
  s.you.meth -= meth;
  s.you.musdc -= musdc;
  const prev = s.you.pendingDeposit;
  s.you.pendingDeposit = {
    batch: s.epoch.id,
    meth: (prev?.meth ?? 0) + meth,
    musdc: (prev?.musdc ?? 0) + musdc,
  };
  emit(s, "info", `You queued ${amount(meth)} mETH and ${amount(musdc)} mUSDC. It joins the vault when this epoch is settled.`);
}

export function settleNow(s: Sim) {
  if (!s.scored && epochEnded(s)) score(s);
  if (s.scored && settleAllowed(s)) settle(s, "you");
}

export function claim(s: Sim) {
  const y = s.you;
  y.shares += y.claimableShares;
  y.meth += y.claimableMeth;
  y.musdc += y.claimableMusdc;
  y.claimableShares = 0;
  y.claimableMeth = 0;
  y.claimableMusdc = 0;
}

export function requestWithdraw(s: Sim, shares: number) {
  if (shares <= 0 || shares > s.you.shares + 1e-9) return;
  s.you.shares -= shares;
  s.you.pendingWithdraw = { batch: s.epoch.id, shares: (s.you.pendingWithdraw?.shares ?? 0) + shares };
  emit(s, "info", `You asked to withdraw ${amount(shares)} shares. They are paid out when this epoch is settled.`);
}
