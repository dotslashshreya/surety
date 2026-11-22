# Static analysis

**Tool:** Slither 0.11.6, run on `src/` only (tests, scripts and the Uniswap and OpenZeppelin libraries excluded):

```bash
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
```

**Result:** 65 findings on the first run. Four were fixed. The remaining 61 are explained below. None is an exploitable issue.

Slither is one layer of evidence. The stronger evidence is in the test suite: 7 invariants over thousands of random actions, 6 attack tests that each end with the attacker no better off, and rounding fuzz tests (see the main README).

## Fixed

| Finding | Where | Fix |
|---|---|---|
| reentrancy-no-eth (Medium) | `_enforceIfDue` minted performance-fee shares before writing the new epoch's state | Moved the mint after every state write |
| reentrancy-no-eth (Medium) | `_processBatch` burned withdrawn shares before recording the batch's payout | Record the payout first, then burn |
| reentrancy-benign (Low) | `requestWithdraw` moved shares before recording the request | Record first, then move |
| reentrancy-benign (Low) | Same enforcement path as above | Fixed by the same move |

These calls go only to `SuretyShares`, the hook's own token, which has no callbacks, so none of them was exploitable. They now follow checks-effects-interactions anyway.

## Explained, not changed

| Finding | Count | Why it isn't a problem |
|---|---|---|
| **weak-prng** (High) | 2 | False positive. Slither flags any `%` involving time-like values. `TwapLib.update` uses `% CARDINALITY` to wrap the observation ring index, and `meanTickBetween` uses `%` to round a mean tick toward negative infinity, as Uniswap v3's oracle does. No randomness is involved anywhere. |
| **reentrancy-no-eth** (Medium) | 13 | Every flagged call is to the `PoolManager` (`modifyLiquidity`, `take`, `settle`, `mint`, `burn`) inside an `unlock` the hook itself opened, or inside the PoolManager's own swap callback. The PoolManager is the trusted v4 singleton, and it does not call a hook's callbacks for that hook's own liquidity changes. The only way back into the hook is `unlockCallback`, which is `onlyPoolManager`. Every external entry point that starts an `unlock` (`settle`, `setRange`, `registerCurator`, `topUpBond`, `claimBond`), plus `deposit`, `requestWithdraw` and `claim`, is `nonReentrant`. Interleaving PoolManager calls with bookkeeping is how v4 accounting works: deltas are netted against ERC-6909 claims at the end of each unlock (`_settleDeltas`), and the invariant suite checks that claims always equal the books. |
| **incorrect-equality** (Medium) | 4 | Each `== 0` check is on internal accounting, never on a balance an attacker can top up by donating: `liq == 0` and `a0 == 0 \|\| a1 == 0` in `_deployAnchor` skip an empty deploy, `supply == 0 \|\| nav == 0` in `_processBatch` handles the very first deposit, and `dt == 0` guards a division in `meanTickBetween`. Because the vault never reads `balanceOf`, donating tokens can't change any of these. |
| **unused-return** (Medium) | 9 | Deliberate. `poolManager.unlock` returns whatever `unlockCallback` returns, which here is always empty. `getSlot0` returns four values and the hook needs only the price or the tick. |
| **uninitialized-local** (Medium) | 6 | False positive. The counters and accumulators (`n`, `totalPerfFee`, `minted`, `froze`, `perfFee`, `ratio`) rely on Solidity's guaranteed zero initialisation. |
| **timestamp** (Low) | 17 | By design. Epochs (30 minutes to 1 day), the 12 s breaker throttle and the TWAP accumulator all use `block.timestamp`. A block producer can shift a timestamp by a few seconds, which is negligible against these windows, and scores use the average over a whole epoch. |
| **calls-loop** (Low) | 3 | Loops run over at most 3 curators (`MAX_CURATORS`), and the calls go to the trusted PoolManager and the hook's own share token, so a loop can't be made to run long or revert because of an untrusted callee. |
| **reentrancy-benign / reentrancy-events** (Low) | 6 | Same as reentrancy-no-eth above: events are emitted after trusted PoolManager or share-token calls, with no way back in. |
| **cyclomatic-complexity** (Informational) | 1 | `_reallocate` has 14 branches because settlement runs as seven ordered steps (anchor, exits, queues, shift, caps, distribution, deploy, reward). Each step is commented in the code and exercised by the settlement, breaker and invariant tests. |
