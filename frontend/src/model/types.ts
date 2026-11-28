import type { Tokens } from "./lpmath";

export type CuratorStatus = "live" | "frozen" | "rearm";

export interface Curator {
  id: string;
  name: string;
  strategy: string;
  lo: number; // range, in mUSDC per mETH
  hi: number;
  L: number; // liquidity in the pool (0 when frozen or waiting)
  v0: number; // starting value this epoch, at the epoch mark price
  fees: number; // fees the slice earned this epoch
  benchFees: number; // fees the benchmark earned this epoch (stop at a freeze)
  bond: number;
  bondStart: number;
  status: CuratorStatus;
  frozen?: Tokens; // tokens parked by the breaker
  pendingRange?: { lo: number; hi: number }; // a new range chosen after a freeze
  lastSlash: number;
  lastFee: number;
  lastExcess: number;
}

export type Tone = "freeze" | "slash" | "gain" | "info";

export interface FeedEvent {
  id: number;
  t: number; // simulation seconds
  tone: Tone;
  text: string;
}

export interface Wallet {
  connected: boolean;
  rightNetwork: boolean;
  gas: number; // test ETH
  meth: number;
  musdc: number;
  shares: number;
  faucetReadyAt: number; // simulation seconds
  pendingDeposit?: { batch: number; meth: number; musdc: number };
  claimableShares: number;
  pendingWithdraw?: { batch: number; shares: number };
  claimableMeth: number;
  claimableMusdc: number;
}

export interface Sim {
  t: number; // simulation seconds since start
  startMs: number; // wall-clock time that t = 0 maps to
  price: number; // spot, mUSDC per mETH
  history: { t: number; p: number }[];
  epoch: { id: number; start: number; length: number };
  mark: number; // the previous epoch's average price: every slice's starting point
  scored: boolean; // the ended epoch has been scored; settle() still has to reallocate
  scoredAt: number;
  shift?: { from: string; to: string }; // capital to move at the next settlement
  curators: Curator[];
  anchorL: number;
  reserve: number; // idle depositor value, in dollars
  supply: number; // vault shares
  rewardPool: number;
  lastCheck: number;
  events: FeedEvent[];
  nextId: number;
  you: Wallet;
}
