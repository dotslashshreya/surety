// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice M3 + M4: TWAP, scoring, in-swap enforcement, slashing, fees, reallocation.
contract SuretySettlementTest is SuretyBase {
    // ---------------------------------------------------------------- M3: TWAP

    function test_twap_tracksTimeWeightedTick() public {
        _bootstrap();
        _swap(true, 5 ether);
        int24 moved = _tick();
        assertLt(moved, 0);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _swap(false, 0.0001 ether); // tiny swap to checkpoint; price barely changes
        // Over the last 5 minutes the tick sat at `moved`.
        assertApproxEqAbs(hook.twapTick(5 minutes), moved, 2);
    }

    function test_twap_resistsSingleBlockSpike() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _swap(true, 20 ether); // spike
        _swap(false, 20 ether); // and back, same block
        int24 t = hook.twapTick(5 minutes);
        assertApproxEqAbs(t, 0, 5, "a same-block round trip does not move the TWAP");
    }

    // ---------------------------------------------------------------- M4: enforcement

    function test_settle_revertsMidEpochWithNothingPending() public {
        _bootstrap();
        vm.expectRevert(SuretyHook.NothingToSettle.selector);
        hook.settle();
    }

    function test_flatMarket_noSlash_feesEarnPerformanceFee() public {
        _bootstrap();
        // Round trips around the starting price: fees, no trend.
        for (uint256 i; i < 20; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _swap(i % 2 == 0, 3 ether);
        }
        _roll();
        (uint256 bondC,, int256 exC,) = hook.curatorState(careful);
        (uint256 bondR,, int256 exR,) = hook.curatorState(reckless);
        assertEq(bondC, 20 ether, "careful not slashed");
        assertEq(bondR, 20 ether, "reckless not slashed");
        assertGt(exC, 0, "concentrated range beats full range on fees");
        assertGt(exR, exC, "tighter range earns more in a flat market");
        assertGt(shares.balanceOf(reckless), 0, "performance fee paid in shares");
        assertGt(shares.balanceOf(careful), 0);
        _assertClaimsMatch();
    }

    function test_trend_slashesReckless_inSwap_thenReallocates() public {
        _bootstrap();
        uint256 capRecklessBefore = hook.sliceValue(1, hook.markSqrtPrice());
        uint256 capCarefulBefore = hook.sliceValue(0, hook.markSqrtPrice());

        // Price trends down early in the epoch, out of the reckless range, and stays there.
        _swap(true, 60 ether);
        assertLt(_tick(), -300, "price left the reckless range");
        vm.warp(hook.epochEnd());

        // The first swap after the epoch ends runs enforcement inside beforeSwap.
        uint256 depositorPotBefore = hook.reserve1() + hook.rewardPool();
        uint64 epochBefore = hook.epochId();
        vm.recordLogs();
        _swap(true, 0.001 ether);
        assertEq(hook.epochId(), epochBefore + 1, "enforced inside the swap");
        assertTrue(hook.reallocPending());
        assertTrue(_sawEvent(SuretyHook.CuratorSlashed.selector), "slash emitted from the swap");

        (uint256 bondR,, int256 exR,) = hook.curatorState(reckless);
        (uint256 bondC,, int256 exC,) = hook.curatorState(careful);
        assertLt(exR, 0, "reckless underperformed the benchmark");
        assertLt(bondR, 20 ether, "reckless bond slashed");
        assertGt(exC, exR, "careful did better");
        assertEq(20 ether - bondR + (20 ether - bondC), hook.reserve1() + hook.rewardPool() - depositorPotBefore, "slash moved to depositors");
        (uint8 from, uint8 to) = hook.pendingShift();
        assertEq(from, 1);
        assertEq(to, 0);
        _assertClaimsMatch();

        // Let the short TWAP catch up with spot, then anyone can settle and earn the reward.
        vm.warp(vm.getBlockTimestamp() + 6 minutes);
        _swap(true, 0.001 ether);
        uint256 rewardBefore = token1.balanceOf(keeper);
        uint256 pool = hook.rewardPool();
        vm.prank(keeper);
        hook.settle();
        assertEq(token1.balanceOf(keeper) - rewardBefore, pool, "keeper paid from slashed bonds");
        assertFalse(hook.reallocPending());

        uint256 capRecklessAfter = hook.sliceValue(1, hook.markSqrtPrice());
        uint256 capCarefulAfter = hook.sliceValue(0, hook.markSqrtPrice());
        assertLt(capRecklessAfter, capRecklessBefore * 80 / 100, "reckless lost capital");
        assertGt(capCarefulAfter, capCarefulBefore, "careful gained capital");
        _assertClaimsMatch();
    }

    function test_slashNeverExceedsBond() public {
        _deposit(alice, 100 ether, 100 ether);
        _register(careful, 20 ether, -6000, 6000);
        _register(reckless, 1 ether, -300, 300); // tiny bond, cap 10
        _roll();
        _swap(true, 40 ether);
        _roll();
        (uint256 bondR,,,) = hook.curatorState(reckless);
        assertEq(bondR, 0, "slash capped at the bond");
        _assertClaimsMatch();
    }

    function test_quietPool_settleStillWorks() public {
        _bootstrap();
        uint64 id = hook.epochId();
        _warpToEpochEnd();
        vm.prank(keeper);
        hook.settle();
        assertEq(hook.epochId(), id + 1);
        (uint256 bondC,,,) = hook.curatorState(careful);
        (uint256 bondR,,,) = hook.curatorState(reckless);
        assertGe(bondC, 20 ether - 10, "no meaningful slash without activity");
        assertGe(bondR, 20 ether - 10);
        _assertClaimsMatch();
    }

    function test_settleOncePerEpoch() public {
        _bootstrap();
        _roll();
        vm.expectRevert(SuretyHook.NothingToSettle.selector);
        hook.settle();
    }

    function test_settleBlockedWhenSpotFarFromTwap() public {
        _bootstrap();
        _warpToEpochEnd();
        _swap(true, 150 ether); // enforcement runs, then spot jumps far from the 5-minute TWAP
        vm.expectRevert(SuretyHook.SpotDeviation.selector);
        hook.settle();
    }

    function test_multipleEpochs_accountingHolds() public {
        _bootstrap();
        for (uint256 e; e < 4; e++) {
            for (uint256 i; i < 6; i++) {
                vm.warp(vm.getBlockTimestamp() + 2 minutes);
                _swap(i % 2 == 0, 2 ether + e * 1 ether);
            }
            vm.warp(vm.getBlockTimestamp() + 6 minutes);
            if (e == 1) {
                vm.prank(alice);
                hook.requestWithdraw(10 ether);
                _deposit(bob, 5 ether, 7 ether);
            }
            _roll();
            _assertClaimsMatch();
        }
        (uint256 bondC,,,) = hook.curatorState(careful);
        assertLe(bondC, 20 ether);
    }

}
