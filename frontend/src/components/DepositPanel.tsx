import { useState, type Dispatch } from "react";
import { STEPS, depositorView } from "../model/depositor";
import { sharePrice } from "../model/engine";
import { amount, clock, countdown, usd } from "../model/format";
import type { Sim } from "../model/types";
import type { Action } from "../model/useSim";

const FAUCETS = [
  { name: "Superchain Faucet", href: "https://console.optimism.io/faucet" },
  { name: "thirdweb faucet", href: "https://thirdweb.com/unichain-sepolia-testnet" },
];

export function DepositPanel({ sim, dispatch }: { sim: Sim; dispatch: Dispatch<Action> }) {
  const v = depositorView(sim);
  const y = sim.you;
  const [meth, setMeth] = useState("");
  const [musdc, setMusdc] = useState("");
  const m = Number(meth) || 0;
  const u = Number(musdc) || 0;
  const depositError =
    m < 0 || u < 0 ? "Amounts can't be negative." : m > y.meth ? "You don't have that much mETH." : u > y.musdc ? "You don't have that much mUSDC." : null;

  return (
    <aside className="deposit" aria-labelledby="deposit-title">
      <h2 id="deposit-title">Your deposit</h2>
      <p className="muted">Try the vault with test tokens. Deposits join when the current epoch is settled.</p>

      <ol className="steps">
        {STEPS.map((step, i) => {
          const state = v.done[step.id] ? "done" : step.id === v.step ? "active" : "todo";
          return (
            <li key={step.id} className={`step step--${state}`} aria-current={state === "active" ? "step" : undefined}>
              <p className="step-title">
                <span className="step-num" aria-hidden="true">
                  {state === "done" ? "✓" : i + 1}
                </span>
                {step.title}
              </p>
              {state === "active" && step.id === "connect" && (
                <button type="button" className="btn btn--primary" onClick={() => dispatch({ type: "connect" })}>
                  Connect wallet
                </button>
              )}
              {state === "active" && step.id === "network" && (
                <button type="button" className="btn btn--primary" onClick={() => dispatch({ type: "switchNetwork" })}>
                  Switch to Unichain Sepolia
                </button>
              )}
              {state === "active" && step.id === "gas" && (
                <div className="step-body">
                  <p>
                    You need a little test ETH to pay for transactions. These faucets work with a new wallet:
                  </p>
                  <ul className="links">
                    {FAUCETS.map((f) => (
                      <li key={f.name}>
                        <a href={f.href} target="_blank" rel="noreferrer">
                          {f.name}
                        </a>
                      </li>
                    ))}
                  </ul>
                  <p className="muted">This page checks your balance every few seconds and moves on when it arrives.</p>
                  <button type="button" className="btn btn--quiet" onClick={() => dispatch({ type: "receiveGas" })}>
                    Preview: pretend test ETH arrived
                  </button>
                </div>
              )}
              {state === "active" && step.id === "tokens" && (
                <div className="step-body">
                  <p>1 mETH and 3,000 mUSDC, once a day per address.</p>
                  <button type="button" className="btn btn--primary" onClick={() => dispatch({ type: "faucet" })}>
                    Get test tokens
                  </button>
                </div>
              )}
              {step.id === "deposit" && (state === "active" || (v.done.tokens && !v.done.deposit)) && (
                <form
                  className="step-body deposit-form"
                  onSubmit={(e) => {
                    e.preventDefault();
                    if (depositError || m + u <= 0) return;
                    dispatch({ type: "deposit", meth: m, musdc: u });
                    setMeth("");
                    setMusdc("");
                  }}
                >
                  <label>
                    <span>mETH</span>
                    <input inputMode="decimal" aria-label="mETH amount" value={meth} placeholder="0" onChange={(e) => setMeth(e.target.value)} />
                    <button type="button" className="link" onClick={() => setMeth(String(y.meth))}>
                      Max {amount(y.meth)}
                    </button>
                  </label>
                  <label>
                    <span>mUSDC</span>
                    <input inputMode="decimal" aria-label="mUSDC amount" value={musdc} placeholder="0" onChange={(e) => setMusdc(e.target.value)} />
                    <button type="button" className="link" onClick={() => setMusdc(String(y.musdc))}>
                      Max {amount(y.musdc)}
                    </button>
                  </label>
                  {depositError && <p className="form-error">{depositError}</p>}
                  <button type="submit" className="btn btn--primary" disabled={!!depositError || m + u <= 0}>
                    Deposit
                  </button>
                </form>
              )}
              {step.id === "shares" && (v.done.deposit || v.hasQueued || v.hasClaim) && (
                <SharesBody sim={sim} dispatch={dispatch} />
              )}
            </li>
          );
        })}
      </ol>
      {v.faucetWait > 0 && v.done.tokens && (
        <p className="muted small">Next test tokens in {countdown(v.faucetWait)}.</p>
      )}
    </aside>
  );
}

function SharesBody({ sim, dispatch }: { sim: Sim; dispatch: Dispatch<Action> }) {
  const v = depositorView(sim);
  const y = sim.you;
  const price = sharePrice(sim);
  return (
    <div className="step-body">
      {y.pendingDeposit && (
        <p>
          {amount(y.pendingDeposit.meth)} mETH and {amount(y.pendingDeposit.musdc)} mUSDC queued.{" "}
          {v.joinsAt !== null ? (
            <>
              Your deposit joins at {clock(sim.startMs, v.joinsAt)}{" "}
              <span className="muted">(in {countdown(v.joinsAt - sim.t)})</span>.
            </>
          ) : (
            <>It joins as soon as the epoch is settled.</>
          )}
        </p>
      )}
      {y.pendingWithdraw && <p>{amount(y.pendingWithdraw.shares)} shares queued to withdraw.</p>}

      {v.canSettle && v.hasQueued && (
        v.settleBlockedFor > 0 ? (
          <p className="notice">
            The price moved sharply. Settling opens once the 5-minute average catches up, in about{" "}
            {Math.ceil(v.settleBlockedFor / 60)} min.
          </p>
        ) : (
          <button type="button" className="btn btn--primary" onClick={() => dispatch({ type: "settle" })}>
            Settle epoch{v.reward > 0 ? ` and earn ${usd(v.reward)}` : ""}
          </button>
        )
      )}

      {v.hasClaim && (
        <button type="button" className="btn btn--primary" onClick={() => dispatch({ type: "claim" })}>
          Claim{" "}
          {y.claimableShares > 0
            ? `${amount(Math.floor(y.claimableShares))} shares`
            : `${amount(y.claimableMeth)} mETH and ${amount(Math.floor(y.claimableMusdc))} mUSDC`}
        </button>
      )}

      {y.shares > 0 && (
        <>
          <p>
            You hold {amount(Math.floor(y.shares))} shares, worth {usd(y.shares * price)}.
          </p>
          {!y.pendingWithdraw && (
            <button type="button" className="btn" onClick={() => dispatch({ type: "withdraw", shares: y.shares })}>
              Withdraw all
            </button>
          )}
        </>
      )}
    </div>
  );
}
