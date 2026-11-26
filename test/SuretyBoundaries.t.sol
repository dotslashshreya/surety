// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice Behaviour exactly at the edges: the TWAP ring wrapping, epoch boundaries, guardrail limits, reward caps.
contract SuretyBoundariesTest is SuretyBase {
    /// The hook keeps 128 TWAP observations. On a live deployment the ring fills within hours and wraps. After that
    /// the TWAP must stay exact, a window longer than the history must clamp instead of reverting, and the breaker
    /// and settlement must keep working.
    function test_twapRing_wrapsAround_staysCorrect() public {
        _bootstrap();
        for (uint256 i; i < 140; i++) {
            vm.warp(vm.getBlockTimestamp() + 13); // above the 12 s minimum, so every swap writes an observation
            _swap(i % 2 == 0, 1e12);
        }
        (uint16 index, uint16 count) = hook.twapRing();
        assertEq(count, 128, "ring is full");
        assertLt(index, 127, "and has wrapped past the end");

        // Move the price and hold it: the 5-minute TWAP must land on the new tick.
        vm.warp(vm.getBlockTimestamp() + 13);
        _swap(true, 30 ether);
        int24 moved = _tick();
        _hold(6 minutes);
        int24 t5 = hook.twapTick(5 minutes);
        assertApproxEqAbs(t5, moved, 2, "5-minute TWAP exact after wrapping");

        // A window longer than the retained history clamps to the oldest observation instead of reverting.
        int24 tDay = hook.twapTick(1 days);
        assertGe(tDay, moved - 2);
        assertLe(tDay, 2);

        // Settlement still works on top of the wrapped ring.
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        vm.prank(keeper);
        hook.settle();
        _assertClaimsMatch();
    }

    /// One second before the epoch ends, a swap does not score it; at the end, it does.
    function test_epochBoundary_oneSecondEarly_doesNotScore() public {
        _bootstrap();
        uint64 id = hook.epochId();
        vm.warp(hook.epochEnd() - 1);
        _swap(true, 1e12);
        assertEq(hook.epochId(), id, "not yet");
        assertFalse(hook.reallocPending());
        vm.warp(vm.getBlockTimestamp() + 1);
        _swap(false, 1e12);
        assertEq(hook.epochId(), id + 1, "scored at exactly epochEnd");
    }

    /// Range centre within D = 1000 ticks of the TWAP. Centres are multiples of 30, so 990 is the last allowed and
    /// 1020 the first rejected, on both sides.
    function test_setRange_centreDistanceLimit() public {
        vm.startPrank(careful);
        hook.registerCurator(5 ether);
        hook.setRange(660, 1320); // centre 990
        vm.expectRevert(SuretyHook.RangeTooFar.selector);
        hook.setRange(720, 1320); // centre 1020
        hook.setRange(-1320, -660); // centre -990
        vm.expectRevert(SuretyHook.RangeTooFar.selector);
        hook.setRange(-1320, -720); // centre -1020
        vm.stopPrank();
    }

    /// Ranges must stay within the usable ticks for the pool's spacing; exactly W_min wide is allowed.
    function test_setRange_tickLimits_andMinWidth() public {
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        vm.startPrank(careful);
        hook.registerCurator(5 ether);
        vm.expectRevert(SuretyHook.InvalidRange.selector);
        hook.setRange(lo - SPACING, 0);
        vm.expectRevert(SuretyHook.InvalidRange.selector);
        hook.setRange(0, hi + SPACING);
        vm.expectRevert(SuretyHook.InvalidRange.selector);
        hook.setRange(-300, 240); // 540 wide: one spacing short of W_min
        hook.setRange(-300, 300); // exactly 600: allowed
        vm.stopPrank();
        assertEq(hook.curatorAt(0).tickUpper - hook.curatorAt(0).tickLower, 600);
    }

    /// R = 3 range changes per epoch; the count resets when a new epoch starts.
    function test_rebalanceCounter_resetsNextEpoch() public {
        vm.startPrank(careful);
        hook.registerCurator(5 ether);
        hook.setRange(-600, 600);
        hook.setRange(-1200, 1200);
        hook.setRange(-1800, 1800);
        vm.expectRevert(SuretyHook.TooManyRebalances.selector);
        hook.setRange(-600, 600);
        vm.stopPrank();

        _warpToEpochEnd();
        vm.prank(keeper);
        hook.settle();

        vm.prank(careful);
        hook.setRange(-600, 600);
        assertEq(hook.curatorAt(0).rebalances, 1, "fresh count in the new epoch");
    }

    /// One settle() pays at most maxSettleReward; the rest waits in the pool for the next caller.
    function test_settleReward_cappedPerCall() public {
        _bootstrap();
        _swap(true, 60 ether);
        vm.warp(hook.epochEnd());
        _swap(true, 0.001 ether); // scores and slashes
        uint256 pool = hook.rewardPool();
        assertGt(pool, 0);
        hook.setMaxSettleReward(pool / 3);

        _hold(6 minutes);
        uint256 before = token1.balanceOf(keeper);
        vm.prank(keeper);
        hook.settle();
        assertEq(token1.balanceOf(keeper) - before, pool / 3, "capped");
        assertEq(hook.rewardPool(), pool - pool / 3, "the rest stays for later callers");
        _assertClaimsMatch();
    }

    /// With no curators and a one-token reserve, the anchor can't be built (full range needs both tokens), so the
    /// deposit waits idle, fully accounted for, instead of reverting.
    function test_anchor_oneSidedReserve_staysIdle() public {
        _deposit(alice, 0, 50 ether);
        _warpToEpochEnd();
        vm.prank(keeper);
        hook.settle();
        assertEq(hook.anchorLiquidity(), 0);
        assertEq(hook.reserve1(), 50 ether);
        assertEq(hook.totalValue(), 50 ether);
        vm.prank(alice);
        (uint256 got,,) = hook.claim(1);
        assertEq(got, 50 ether);
        _assertClaimsMatch();
    }
}
