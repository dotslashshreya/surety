// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TwapLib} from "../src/libraries/TwapLib.sol";

/// @notice Exposes TwapLib's storage-based functions for direct testing.
contract TwapHarness {
    using TwapLib for TwapLib.State;

    TwapLib.State internal s;

    function init(int24 tick) external {
        s.initialize(tick);
    }

    function update(int24 tick) external {
        s.update(tick);
    }

    function meanTick(uint32 window) external view returns (int24) {
        return s.meanTick(window);
    }

    function cumulativeAt(uint32 t) external view returns (int56) {
        return s.cumulativeAt(t);
    }

    function between(int56 a, int56 b, uint32 dt) external pure returns (int24) {
        return TwapLib.meanTickBetween(a, b, dt);
    }

    function ring() external view returns (uint16 index, uint16 count) {
        return (s.index, s.count);
    }
}

/// @notice Unit and fuzz tests for the TWAP accumulator and its observation ring.
contract TwapLibTest is Test {
    TwapHarness h;

    function setUp() public {
        vm.warp(1_700_000_000);
        h = new TwapHarness();
    }

    function _at(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
    }

    function test_uninitialized_reverts() public {
        vm.expectRevert(TwapLib.NotInitialized.selector);
        h.cumulativeAt(uint32(vm.getBlockTimestamp()));
    }

    function test_futureTime_reverts() public {
        h.init(0);
        vm.expectRevert(TwapLib.FutureTime.selector);
        h.cumulativeAt(uint32(vm.getBlockTimestamp() + 1));
    }

    function test_meanTickBetween_zeroDuration_reverts() public {
        vm.expectRevert(TwapLib.FutureTime.selector);
        h.between(0, 0, 0);
    }

    /// Like Uniswap v3: the mean tick rounds toward negative infinity.
    function test_meanTickBetween_roundsDown() public view {
        assertEq(h.between(0, -3, 2), -2); // -1.5 → -2
        assertEq(h.between(0, 3, 2), 1); // 1.5 → 1
        assertEq(h.between(0, -4, 2), -2); // exact
    }

    /// Between the newest stored observation and the latest swap (less than 12 s apart, so not stored), the
    /// cumulative is interpolated, and it is exact because the tick was constant over that stretch.
    function test_cumulative_betweenNewestObservationAndLiveSwap() public {
        h.init(0);
        uint256 t0 = vm.getBlockTimestamp();
        _at(20);
        h.update(100); // stored observation at t0+20 (cum 0); tick 100 from here
        _at(5);
        h.update(200); // t0+25, 5 s later: not stored
        assertEq(h.cumulativeAt(uint32(t0 + 22)), 200, "100 ticks x 2 s");
    }

    /// After hundreds of observations the ring has wrapped many times, and averages are still exact.
    function test_ringWraps_averagesStayExact() public {
        h.init(0);
        for (uint256 i; i < 300; i++) {
            _at(13);
            h.update(i % 2 == 0 ? int24(100) : int24(-100));
        }
        (, uint16 count) = h.ring();
        assertEq(count, 128);

        _at(13);
        h.update(500);
        _at(300);
        h.update(500);
        assertEq(h.meanTick(300), 500, "the last 5 minutes sat exactly at 500");
    }

    /// A window longer than the stored history clamps to the oldest observation.
    function test_windowLongerThanHistory_clamps() public {
        h.init(0);
        for (uint256 i; i < 200; i++) {
            _at(13);
            h.update(1000);
        }
        assertEq(h.meanTick(30 days), 1000, "only tick 1000 is still in the ring");
    }

    /// Whatever ticks were held, for however long, the mean over any window lies between the lowest and highest.
    function testFuzz_meanTick_staysWithinRecordedTicks(int24[8] memory ticks, uint16[8] memory gaps, uint32 window)
        public
    {
        int24 init = int24(bound(int256(ticks[0]), TickMath.MIN_TICK, TickMath.MAX_TICK));
        h.init(init);
        int24 lo = init;
        int24 hi = init;
        uint256 total;
        for (uint256 i; i < 8; i++) {
            uint256 gap = bound(gaps[i], 1, 600);
            total += gap;
            _at(gap);
            int24 t = int24(bound(int256(ticks[i]), TickMath.MIN_TICK, TickMath.MAX_TICK));
            h.update(t);
            if (t < lo) lo = t;
            if (t > hi) hi = t;
        }
        window = uint32(bound(window, 1, total + 1000));
        int24 m = h.meanTick(window);
        assertGe(m, lo);
        assertLe(m, hi);
    }

    /// If the tick never changes, every window's mean is that tick.
    function testFuzz_meanTick_constantTick(int24 tick, uint16 gap, uint32 window) public {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        h.init(tick);
        for (uint256 i; i < 20; i++) {
            _at(bound(gap, 1, 120));
            h.update(tick);
        }
        assertEq(h.meanTick(uint32(bound(window, 1, 10 days))), tick);
    }
}
