// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";
import {ScoreLib} from "../src/libraries/ScoreLib.sol";

/// @notice M5: drawdown breaker. Freeze, never slash.
contract SuretyBreakerTest is SuretyBase {
    using StateLibrary for IPoolManager;

    uint256 constant SHOCK = 80 ether; // token0 sold into the pool: pushes price well below the reckless range
    uint8 constant CAREFUL = 0;
    uint8 constant RECKLESS = 1;

    // ---------------------------------------------------------------- helpers


    function _shock() internal {
        vm.warp(vm.getBlockTimestamp() + 60);
        _swap(true, SHOCK);
    }

    function _frozen(uint8 i) internal view returns (bool) {
        return hook.curatorAt(i).frozen;
    }

    // ---------------------------------------------------------------- tests

    function test_shockMovesPriceOutOfRecklessRange() public {
        _bootstrap();
        _shock();
        int24 t = _tick();
        assertLt(t, -1500, "shock large enough to matter");
        assertGt(t, -6000, "still inside the careful range");
    }

    /// The breaker reads the 5-minute TWAP, so a sudden move alone freezes nobody.
    function test_shockAloneDoesNotFreeze() public {
        _bootstrap();
        _shock();
        assertEq(hook.lastBreakerCheck(), vm.getBlockTimestamp(), "the check ran on the shock swap");
        assertFalse(_frozen(RECKLESS), "TWAP has not caught up yet");
        assertFalse(_frozen(CAREFUL));
    }

    function test_shockAndHold_freezesReckless_onlyReckless() public {
        _bootstrap();
        uint256 bondBefore = hook.curatorAt(RECKLESS).bond;
        _shock();
        vm.recordLogs();
        _hold(6 minutes);

        SuretyHook.Curator memory r = hook.curatorAt(RECKLESS);
        assertTrue(r.frozen, "reckless frozen once the TWAP caught up");
        assertEq(r.liquidity, 0, "its liquidity was pulled out of the pool");
        assertGt(r.idle0 + r.idle1, 0, "parked idle in the hook");
        assertEq(r.bond, bondBefore, "the breaker never touches a bond");
        assertFalse(_frozen(CAREFUL), "careful stays live");
        assertTrue(_sawEvent(SuretyHook.CuratorFrozen.selector));
        _assertClaimsMatch();
    }

    /// Trip exactly at X = 5%: 4.9% below the benchmark stays live, 5.1% freezes.
    function test_threshold() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1); // past the gate's max age: the full check runs
        _swap(true, 1e9); // checkpoint; no meaningful price move
        (uint256 v,) = hook.liveScore(RECKLESS);

        hook.setV0(RECKLESS, v * 10_000 / 9_510); // benchmark ≈ v0 at an unchanged price: 4.9% shortfall
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1); // past the gate's max age: the full check runs
        _swap(false, 1e9);
        assertFalse(_frozen(RECKLESS), "4.9% below: still live");

        hook.setV0(RECKLESS, v * 10_000 / 9_490); // 5.1% shortfall
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1); // past the gate's max age: the full check runs
        _swap(true, 1e9);
        assertTrue(_frozen(RECKLESS), "5.1% below: frozen");
    }

    function test_throttle_checksAtMostEvery12Seconds() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 100);
        _swap(true, 1e12);
        uint32 first = hook.lastBreakerCheck();
        assertEq(first, vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + 5);
        uint256 g = gasleft();
        _swap(false, 1e12);
        uint256 skipped = g - gasleft();
        assertEq(hook.lastBreakerCheck(), first, "second swap within 12 s skipped the check");

        vm.warp(vm.getBlockTimestamp() + 12);
        g = gasleft();
        _swap(true, 1e12);
        uint256 checked = g - gasleft();
        assertEq(hook.lastBreakerCheck(), vm.getBlockTimestamp(), "ran again after 12 s");
        assertLt(skipped, checked, "skipping the check is cheaper");
    }

    function test_frozenCuratorCannotSetRangeMidEpoch() public {
        _bootstrap();
        _shock();
        _hold(6 minutes);
        assertTrue(_frozen(RECKLESS));
        vm.prank(reckless);
        vm.expectRevert(SuretyHook.CuratorFrozenErr.selector);
        hook.setRange(-1800, -1200);
    }

    /// The demo: frozen mid-epoch, slashed at settlement, capital to the careful curator, re-arm to come back.
    function test_demo_freezeThenSlashThenRearm() public {
        _bootstrap();
        uint256 carefulBefore = hook.sliceValue(CAREFUL, hook.markSqrtPrice());
        _shock();
        _hold(6 minutes);
        assertTrue(_frozen(RECKLESS));

        // Epoch ends while the price stays down; spot and the short TWAP agree, so settle() is allowed.
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        vm.prank(keeper);
        hook.settle();

        SuretyHook.Curator memory r = hook.curatorAt(RECKLESS);
        assertLt(r.bond, 20 ether, "slashed at settlement");
        assertLt(r.lastExcess, 0);
        assertFalse(r.frozen, "freeze cleared at settlement");
        assertTrue(r.needsRearm, "must re-arm before getting capital");
        assertFalse(r.active);
        assertEq(r.idle0 + r.idle1 + r.liquidity, 0, "slice returned to depositors");
        assertGt(hook.sliceValue(CAREFUL, hook.markSqrtPrice()), carefulBefore, "capital moved to careful");
        _assertClaimsMatch();

        // Re-arm: a fresh narrow range near the current price, then it rejoins at the next reallocation.
        int24 t = hook.twapTick(5 minutes);
        int24 centre = (t / SPACING) * SPACING;
        vm.prank(reckless);
        hook.setRange(centre - 300, centre + 300);
        assertFalse(hook.curatorAt(RECKLESS).needsRearm);
        _deposit(bob, 20 ether, 20 ether); // new money for the reserve to hand out
        _hold(2 minutes);
        _roll();
        assertTrue(hook.curatorAt(RECKLESS).active, "back in after re-arming");
        assertGt(hook.curatorAt(RECKLESS).liquidity, 0);
        _assertClaimsMatch();
    }

    /// Without re-arming, a frozen curator gets nothing next epoch.
    function test_noRearm_noCapital() public {
        _bootstrap();
        _shock();
        _hold(6 minutes);
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        _roll();
        _deposit(bob, 20 ether, 20 ether);
        _hold(2 minutes);
        _roll();
        assertFalse(hook.curatorAt(RECKLESS).active);
        assertEq(hook.sliceValue(RECKLESS, hook.markSqrtPrice()), 0);
    }

    /// Griefing: push the price to trip a rival, then push it back. The rival's benchmark stops earning fees at the
    /// freeze, so it isn't slashed for fees it couldn't earn, and the attacker ends poorer.
    function test_griefing_freezeDoesNotCostRivalTheFees_attackerLoses() public {
        _bootstrap();
        (uint256 fgStart0, uint256 fgStart1) = poolManager.getFeeGrowthGlobals(poolId);
        uint160 markBefore = hook.markSqrtPrice();
        uint256 a0 = token0.balanceOf(address(this));
        uint256 a1 = token1.balanceOf(address(this));

        // Attacker (this contract) pushes the price down and holds it until the rival freezes...
        uint256 b1 = token1.balanceOf(address(this));
        _shock();
        uint256 received = token1.balanceOf(address(this)) - b1;
        _hold(6 minutes);
        assertTrue(_frozen(RECKLESS));
        // ...then pushes it back up with what it received, generating fees the frozen rival can no longer earn.
        _swap(false, received);
        _hold(6 minutes);

        // The epoch is scored by the first swap after it ends: capture fee growth just before that swap.
        vm.warp(hook.epochEnd());
        (uint256 fgEnd0, uint256 fgEnd1) = poolManager.getFeeGrowthGlobals(poolId);
        vm.recordLogs();
        _hold(1 minutes);
        vm.prank(keeper);
        hook.settle();

        // Rebuild the benchmark the rival would have faced without the fee snapshot.
        (uint256 v0, , uint256 bUsed) = _scored(reckless);
        uint256 bFull = ScoreLib.benchmark(v0, markBefore, hook.markSqrtPrice(), fgEnd0 - fgStart0, fgEnd1 - fgStart1);
        assertLt(bUsed, bFull, "benchmark stopped earning fees at the freeze");

        // The attacker paid fees both ways and lost to price impact.
        (uint160 sqrtNow,,,) = poolManager.getSlot0(poolId);
        uint256 before = ScoreLib.value(a0, a1, sqrtNow);
        uint256 afterV = ScoreLib.value(token0.balanceOf(address(this)), token1.balanceOf(address(this)), sqrtNow);
        assertLt(afterV, before, "attacker ends poorer");
        _assertClaimsMatch();
    }

    /// The gas gate: in a quiet market the 12 s check skips the valuation; after a move it keeps running every 12 s
    /// until the TWAP catches up (so it never delays a freeze); then it skips again; after 5 minutes it runs regardless.
    function test_gate_quietSkips_moveKeepsChecking_ageForcesCheck() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 60);
        _swap(true, 1e12);
        uint32 first = hook.lastFullCheck();
        assertEq(first, vm.getBlockTimestamp(), "first check runs (nothing checked yet)");

        vm.warp(vm.getBlockTimestamp() + 13);
        _swap(false, 1e12);
        assertEq(hook.lastBreakerCheck(), vm.getBlockTimestamp(), "the throttle let this swap look");
        assertEq(hook.lastFullCheck(), first, "quiet market: the gate skipped the valuation");

        int24 before = _tick();
        vm.warp(vm.getBlockTimestamp() + 13);
        _swap(true, 10 ether);
        assertGe(before - _tick(), 20, "the price moved at least 20 ticks");
        assertEq(hook.lastFullCheck(), vm.getBlockTimestamp(), "a move passes the gate");

        vm.warp(vm.getBlockTimestamp() + 13);
        _swap(false, 1e12);
        assertEq(hook.lastFullCheck(), vm.getBlockTimestamp(), "TWAP still lagging spot: checks keep running");

        _hold(6 minutes); // the TWAP catches up with spot
        vm.warp(vm.getBlockTimestamp() + 13);
        _swap(true, 1e12);
        uint32 settled = hook.lastFullCheck();
        assertLt(settled, vm.getBlockTimestamp(), "TWAP caught up, price quiet again: skipped");

        vm.warp(uint256(settled) + 5 minutes + 1);
        _swap(false, 1e12);
        assertEq(hook.lastFullCheck(), vm.getBlockTimestamp(), "5 minutes since the last full check: runs anyway");
    }

    /// The anchor keeps about 10% of depositor capital full range, outside every curator's control.
    function test_anchorHoldsTenPercent() public {
        _bootstrap();
        uint160 mark = hook.markSqrtPrice();
        uint256 curated = hook.sliceValue(CAREFUL, mark) + hook.sliceValue(RECKLESS, mark);
        uint256 loose = ScoreLib.value(hook.reserve0(), hook.reserve1(), mark);
        uint256 anchorValue = hook.totalValue() - curated - loose;
        assertApproxEqRel(anchorValue, 20 ether, 0.01e18, "10% of the 200 deposited");
        assertGt(hook.anchorLiquidity(), 0);
    }

    /// Even with every curator frozen, the anchor keeps liquidity at every price: a tiny swap can't fling the price,
    /// so nobody can set a fake price for free and have settle() redeploy depositors' money at it.
    function test_allCuratorsFrozen_poolStillHasLiquidity() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1); // past the gate's max age: the full check runs
        _swap(true, 1e9);
        (uint256 vc,) = hook.liveScore(CAREFUL);
        (uint256 vr,) = hook.liveScore(RECKLESS);
        hook.setV0(CAREFUL, vc * 2); // both far below their benchmarks
        hook.setV0(RECKLESS, vr * 2);
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1); // past the gate's max age: the full check runs
        _swap(false, 1e9);
        assertTrue(_frozen(CAREFUL) && _frozen(RECKLESS), "every curator frozen");
        assertEq(hook.curatorAt(CAREFUL).liquidity + hook.curatorAt(RECKLESS).liquidity, 0);

        int24 before = _tick();
        _swap(true, 1e12);
        _swap(false, 1e12);
        int24 drift = _tick() - before;
        assertLt(drift < 0 ? -drift : drift, 5, "tiny swaps barely move the price");

        // Moving the price far now costs real money against the anchor.
        uint256 b1 = token1.balanceOf(address(this));
        _swap(true, 5 ether);
        // Full-range maths with L ≈ 10: selling 5 token0 returns 10 - 100/15 ≈ 3.33 and moves the price to ≈ 0.44.
        assertApproxEqRel(token1.balanceOf(address(this)) - b1, 3.33 ether, 0.02e18, "a real trade, not a free jump");
        assertGt(_tick(), -10_000, "price moved a bounded amount, nowhere near the minimum tick");
        _assertClaimsMatch();
    }

    // ---------------------------------------------------------------- log helpers


    function _scored(address who) internal returns (uint256 v0, uint256 v1, uint256 b) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].topics.length == 3 && logs[i].topics[0] == SuretyHook.CuratorScored.selector
                    && address(uint160(uint256(logs[i].topics[2]))) == who
            ) {
                return abi.decode(logs[i].data, (uint256, uint256, uint256));
            }
        }
        revert("no CuratorScored event");
    }
}
