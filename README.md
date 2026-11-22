# Surety

**The first LP manager who pays you back when they lose.**

Surety is a Uniswap v4 hook (UHI11) in which curators manage the hook's liquidity. Each curator posts a bond, and when it underperforms a passive benchmark that bond repays depositors.

- The hook owns all of one pool's liquidity. Each curator manages a separate slice through a guardrailed `setRange`, and can only move liquidity, never swap.
- Every epoch, each slice is scored against a **full-range LP of the same starting value**. The benchmark is computed onchain from the pool's own fee growth, and both sides are marked at the hook's epoch-long TWAP.
- **Enforcement runs inside the first swap after an epoch ends.** That covers scoring, slashing and performance fees, and it is bookkeeping only. Reallocation moves liquidity, so it runs from `settle()`, which anyone can call for a reward paid out of slashed bonds. There is no keeper.
- Settlement never swaps. Liquidity is only added when spot is close to the short TWAP.
- **Drawdown breaker: freeze, never slash.** Mid-epoch, a slice that falls more than 5% below its benchmark (both marked at the 5-minute TWAP, never spot) is pulled out of the pool and parked. The slash still happens at settlement, at the epoch-long TWAP. The frozen curator's benchmark stops earning fees at the freeze, so a wrongful freeze, even one triggered on purpose by a rival, costs it only the fees it missed. A frozen curator gets no capital until it picks a new range.
- **Full-range anchor.** 10% of depositor capital always sits in the hook's own full-range position, which is literally the benchmark. It is never frozen, so the pool is never empty and moving the price always costs real money. Without it, a pool whose curators are all frozen (or all narrow) could be pushed to any price for free, and `settle()` would redeploy depositors' money at that price.

## Status

| Milestone | State |
|---|---|
| M1 Vault core: hook-owned liquidity, queued deposit/withdraw | done |
| M2 Curators: bonds, guardrailed `setRange`, exit with bond lock | done |
| M3 TWAP + scoring: accumulator, fee-growth benchmark | done |
| M4 Enforcement + settlement: slash, perf fee, in-swap trigger, reallocation, reward | done |
| M5 Drawdown breaker (freeze, never slash), full-range anchor | done |
| M6 Deposit pricing fix, invariant suite, attack and fuzz tests, gas table, static analysis | done |
| M7 Testnet deploy, curator scripts, frontend, video | — |

## Layout

```
src/SuretyHook.sol          hook + vault + curators + settlement
src/SuretyShares.sol        vault share token (only the hook mints/burns)
src/libraries/TwapLib.sol   tick accumulator + small observation ring
src/libraries/ScoreLib.sol  valuation and the full-range benchmark
src/libraries/SuretyMath.sol  linked library: tick maths, position valuation, benchmark
                            (keeps SuretyHook under the 24 KB deploy limit)
test/                       see "Tests" below
snapshots/surety-gas.json   gas figures behind the table below
audit/README.md             Slither results: what was fixed, and why the rest isn't a problem
```

## Benchmark

```
B = V0·√(P1/P0) + L_b·(Δg0·P1 + Δg1) / 2^128,   L_b = V0 / (2·√P0)
```

Δg0 and Δg1 are the changes in `feeGrowthGlobal` over the epoch. A full-range position's boundary ticks are never crossed, so its fee growth inside equals the change in the global figure. *We measure skill, not market direction.*

Rounding always favours depositors: curator value rounds down and the benchmark rounds up. Deposits get shares rounded down, and withdrawals are paid in kind, rounded down.

Queued deposits are priced at the 5-minute TWAP when `settle()` processes them, not at the epoch-long mark. After a late trend the mark overvalues one token, and a one-sided deposit of it would otherwise dilute everyone else.

## Tests

60 tests, all passing (`forge test`):

| Suite | What it shows |
|---|---|
| `ScoreLib.t.sol` | Benchmark maths against a hand calculation and against a real full-range position |
| `SuretyVault.t.sol` | Vault core, queues, curators, guardrails, capital cap, exit and bond lock |
| `SuretySettlement.t.sol` | TWAP, in-swap enforcement, slashing, performance fees, reallocation, settle reward |
| `SuretyBreaker.t.sol` | Shock alone doesn't freeze (TWAP lag); exact 5% threshold; 12 s throttle; freeze, then slash, then re-arm; anchor keeps the pool liquid with every curator frozen |
| `SuretyAttacks.t.sol` | Each attack ends with the attacker no better off (see below) |
| `SuretyFuzz.t.sol` | Deposit then withdraw never returns more than went in; any range move is value-neutral |
| `SuretyInvariant.t.sol` | 7 invariants over 7,680 random actions per run (deposits, withdrawals, claims, swaps, time, range moves, settlements) |
| `SuretyGas.t.sol` | The gas table below |

**Attacks, each ending with the attacker no better off:**

| Attack | Defence | Test |
|---|---|---|
| Wash-trade through your own range | You pay every swap fee and get back at most 20% of the excess; depositors keep the rest | `test_washTrading_curatorEndsPoorer` |
| Push the price at the epoch boundary | Scores use the epoch-long TWAP: a 12 s push moves the score by under 0.5% | `test_boundaryPush_barelyMovesScore_attackerPoorer` |
| Push the price to trip a rival's breaker | The breaker only freezes, and a frozen curator's benchmark stops earning fees at the freeze | `test_griefing_freezeDoesNotCostRivalTheFees_attackerLoses` |
| Deposit only the token a stale price overvalues | Deposits are priced at the 5-minute TWAP at settlement | `test_depositTiming_oneSidedDepositAfterTrendDoesNotPay` |
| Sandwich the reallocation | `settle()` refuses to add liquidity while spot is more than about 5% from the 5-minute TWAP | `test_sandwichReallocation_blockedBySpotGuard` |
| Empty the pool, then set a fake price for free | The full-range anchor is never frozen, so moving the price always costs real money | `test_allCuratorsFrozen_poolStillHasLiquidity` |

**Invariants:**
1. ERC-6909 claims equal the books.
2. The ERC20 balance equals queued deposits plus unclaimed withdrawals.
3. Bonds never increase.
4. The breaker never changes a bond.
5. Settlement happens at most once per epoch.
6. Capital stays within k × bond after reallocation.
7. The epoch clock stays consistent.

## Gas

Each figure is the gas of one call, measured cold as in a real transaction. The baseline is the same swap through an identical pool with no hook.

| Path | Gas | How often |
|---|---|---|
| Swap, no hook (baseline) | 121,167 | — |
| **Swap, breaker check skipped** | **150,503** | almost every swap |
| Swap that runs the breaker check | 289,781 | at most once every 12 s |
| Swap that ends an epoch (scoring, slashing, fees) | 570,672 | once per epoch |
| Swap that trips the breaker | 436,885 | rare |
| `settle()` with reallocation | 591,119 | once per epoch, paid from slashed bonds |

## Build and test

```bash
forge build --sizes   # SuretyHook must stay under 24,576 bytes
forge test
```

Compiling with `via_ir` takes a few minutes. Tests use `vm.getBlockTimestamp()` rather than `block.timestamp`, because via_ir caches the latter across `vm.warp`.

## Static analysis

Slither 0.11.6 on `src/`: 65 findings, 4 fixed, the other 61 explained one by one in [audit/README.md](audit/README.md). None is exploitable; the two marked High are a known false positive on modulo arithmetic.

## Known limitations

- Losses beyond a curator's bond are not covered. The `k × bond` capital cap keeps the bond meaningful relative to the slice, and the breaker trips at 5%, half the bond's 10% coverage, so only a sudden gap move gets past both.
- `settle()` still adds liquidity anywhere inside a band of about 5% around the 5-minute TWAP, so a sandwich within that band is bounded but not impossible. Moving the price that far against the pool's liquidity, anchor included, costs the attacker fees and price impact.

Future work: multi-pool support, yield-bearing bonds, governance over parameters.
