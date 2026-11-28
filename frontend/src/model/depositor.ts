import { PARAMS, epochEnded, settleAllowed } from "./engine";
import type { Sim } from "./types";

export type Step = "connect" | "network" | "gas" | "tokens" | "deposit" | "shares";

export const STEPS: { id: Step; title: string }[] = [
  { id: "connect", title: "Connect a wallet" },
  { id: "network", title: "Switch to Unichain Sepolia" },
  { id: "gas", title: "Get a little test ETH for gas" },
  { id: "tokens", title: "Get test tokens" },
  { id: "deposit", title: "Deposit" },
  { id: "shares", title: "Claim your shares" },
];

export interface DepositorView {
  step: Step; // the first step not done yet
  done: Record<Step, boolean>;
  faucetWait: number; // seconds until the faucet can be used again
  joinsAt: number | null; // simulation second the queued deposit joins (null: right at the next settle)
  hasQueued: boolean;
  canSettle: boolean; // an epoch has ended and settle() would do something
  settleBlockedFor: number; // seconds until spot and the 5-minute TWAP agree again (0: not blocked)
  reward: number;
  hasClaim: boolean;
}

export function depositorView(s: Sim): DepositorView {
  const y = s.you;
  const holdsSomething =
    y.meth + y.musdc + y.shares + y.claimableShares > 0 || !!y.pendingDeposit || !!y.pendingWithdraw;
  const done: Record<Step, boolean> = {
    connect: y.connected,
    network: y.connected && y.rightNetwork,
    gas: y.gas > 0,
    tokens: holdsSomething,
    deposit: !!y.pendingDeposit || y.shares + y.claimableShares > 0,
    shares: y.shares > 0 && !y.pendingDeposit && y.claimableShares === 0,
  };
  const step = STEPS.find((x) => !done[x.id])?.id ?? "shares";

  let joinsAt: number | null = null;
  if (y.pendingDeposit && y.pendingDeposit.batch >= s.epoch.id) joinsAt = s.epoch.start + s.epoch.length;

  const canSettle = epochEnded(s) || s.scored;
  let settleBlockedFor = 0;
  if (canSettle && !settleAllowed(s)) {
    const lastMove = s.history[s.history.length - 1].t;
    settleBlockedFor = Math.max(30, PARAMS.twapWindow - (s.t - lastMove));
  }

  return {
    step,
    done,
    faucetWait: Math.max(0, y.faucetReadyAt - s.t),
    joinsAt,
    hasQueued: !!y.pendingDeposit || !!y.pendingWithdraw,
    canSettle,
    settleBlockedFor,
    reward: Math.min(s.rewardPool, PARAMS.maxReward),
    hasClaim: y.claimableShares > 0 || y.claimableMeth + y.claimableMusdc > 0,
  };
}
