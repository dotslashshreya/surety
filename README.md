# Surety

**The first LP manager who pays you back when they lose.**

Surety is a Uniswap v4 hook (UHI11) in which curators manage the hook's liquidity. Each curator posts a bond, and when it underperforms a passive benchmark that bond repays depositors.

- The hook owns all of one pool's liquidity. Each curator manages a separate slice through a guardrailed `setRange`, and can only move liquidity, never swap.
- Every epoch, each slice is scored against a **full-range LP of the same starting value**. The benchmark is computed onchain from the pool's own fee growth, and both sides are marked at the hook's epoch-long TWAP.
- **Enforcement runs inside the first swap after an epoch ends.** That covers scoring, slashing and performance fees, and it is bookkeeping only. Reallocation moves liquidity, so it runs from `settle()`, which anyone can call for a reward paid out of slashed bonds. There is no keeper.
- Settlement never swaps. Liquidity is only added when spot is close to the short TWAP.

## Status

| Milestone | State |
|---|---|
| M1 Vault core: hook-owned liquidity, queued deposit/withdraw | done |
| M2 Curators: bonds, guardrailed `setRange`, exit with bond lock | done |
| M3 TWAP + scoring: accumulator, fee-growth benchmark | done |
| M4 Enforcement + settlement: slash, perf fee, in-swap trigger, reallocation, reward | done |
| M5 Drawdown breaker (freeze, never slash) | next |
| M6 Invariant suite, attack tests, gas snapshot | — |
| M7 Testnet deploy, curator scripts, frontend, video | — |

## Layout

```
src/SuretyHook.sol          hook + vault + curators + settlement
src/SuretyShares.sol        vault share token (only the hook mints/burns)
src/libraries/TwapLib.sol   tick accumulator + small observation ring
src/libraries/ScoreLib.sol  valuation and the full-range benchmark
test/                       ScoreLib unit tests, vault/curator tests, settlement scenarios
```

## Benchmark

```
B = V0·√(P1/P0) + L_b·(Δg0·P1 + Δg1) / 2^128,   L_b = V0 / (2·√P0)
```

Δg0 and Δg1 are the changes in `feeGrowthGlobal` over the epoch. A full-range position's boundary ticks are never crossed, so its fee growth inside equals the change in the global figure. *We measure skill, not market direction.*

Rounding always favours depositors: curator value rounds down and the benchmark rounds up. Deposits get shares rounded down, and withdrawals are paid in kind, rounded down.

## Build and test

```bash
forge build --sizes   # SuretyHook must stay under 24,576 bytes
forge test
```

Compiling with `via_ir` takes a few minutes. Tests use `vm.getBlockTimestamp()` rather than `block.timestamp`, because via_ir caches the latter across `vm.warp`.

## Known limitations

- Losses beyond a curator's bond are not covered. The `k × bond` capital cap keeps the bond meaningful relative to the slice.
- Deposits are priced at the previous epoch's TWAP, so a depositor can gain slightly when spot diverges from it at the boundary.

Future work: multi-pool support, yield-bearing bonds, governance over parameters.
