// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";
import {ScoreLib} from "../src/libraries/ScoreLib.sol";
import {SuretyMath} from "../src/libraries/SuretyMath.sol";

/// @notice M6 fuzz tests for rounding. Bunni lost about $8.4M to a rounding flaw in a v4 hook, so every share and
///         amount calculation here rounds in the vault's favour, and these tests hold it to that.
contract SuretyFuzzTest is SuretyBase {
    /// Deposit any amounts, then withdraw every share. With no trading in between, the depositor never gets back
    /// more than it put in, and loses at most dust.
    function testFuzz_depositThenWithdraw_neverReturnsMore(uint256 a0, uint256 a1) public {
        a0 = bound(a0, 0, 100_000 ether);
        a1 = bound(a1, 0, 100_000 ether);
        vm.assume(a0 + a1 >= 1e6);
        _bootstrap(); // capital above the curators' caps goes to the full-range anchor

        uint256 depId = hook.openBatch();
        _deposit(alice, a0, a1);
        _roll();
        vm.prank(alice);
        (uint256 got,,) = hook.claim(depId);

        uint256 wId = hook.openBatch();
        vm.prank(alice);
        hook.requestWithdraw(got);
        _roll();
        vm.prank(alice);
        (, uint256 out0, uint256 out1) = hook.claim(wId);

        // No swaps happened, so the price is still exactly 1 and value is just the sum of both tokens.
        assertLe(out0 + out1, a0 + a1, "never more than was deposited");
        assertGe(out0 + out1 + 100, (a0 + a1) - (a0 + a1) / 1e9, "loses at most dust");
        _assertClaimsMatch();
    }

    /// Any valid range change only moves the curator's own liquidity: total value is unchanged and no tokens leave.
    function testFuzz_setRange_isValueNeutral(int256 centreSteps, uint256 halfWidthSteps) public {
        _bootstrap();
        int24 centre = int24(bound(centreSteps, -15, 15)) * SPACING;
        int24 half = int24(int256(bound(halfWidthSteps, 5, 50))) * SPACING;
        uint256 navBefore = hook.totalValue();
        uint256 erc0 = token0.balanceOf(address(hook));
        uint256 erc1 = token1.balanceOf(address(hook));

        vm.prank(careful);
        hook.setRange(centre - half, centre + half);

        assertApproxEqAbs(hook.totalValue(), navBefore, 20, "value unchanged by a range move");
        assertEq(token0.balanceOf(address(hook)), erc0, "no tokens left the hook");
        assertEq(token1.balanceOf(address(hook)), erc1);
        _assertClaimsMatch();
    }

    /// Any (tickLower, tickUpper): setRange succeeds exactly when every guardrail holds, and otherwise reverts with
    /// the error for the first rule broken. Half the runs use ticks snapped to the spacing so both outcomes occur.
    function testFuzz_setRange_guardrails(int256 a, int256 b, bool snap) public {
        int24 tl;
        int24 tu;
        if (snap) {
            tl = int24(bound(a, -40, 40)) * SPACING;
            tu = int24(bound(b, -40, 40)) * SPACING;
        } else {
            tl = int24(bound(a, type(int24).min, type(int24).max));
            tu = int24(bound(b, type(int24).min, type(int24).max));
        }
        vm.startPrank(careful);
        hook.registerCurator(5 ether);

        bool invalid = tl >= tu || tl % SPACING != 0 || tu % SPACING != 0 || tl < TickMath.minUsableTick(SPACING)
            || tu > TickMath.maxUsableTick(SPACING) || tu - tl < 10 * SPACING;
        int256 centre = (int256(tl) + int256(tu)) / 2; // the TWAP tick is 0: nothing has traded yet
        if (invalid) {
            vm.expectRevert(SuretyHook.InvalidRange.selector);
        } else if (centre > 1000 || centre < -1000) {
            vm.expectRevert(SuretyHook.RangeTooFar.selector);
        }
        hook.setRange(tl, tu);
        vm.stopPrank();
        if (!invalid && centre <= 1000 && centre >= -1000) {
            assertEq(hook.curatorAt(0).tickLower, tl);
            assertEq(hook.curatorAt(0).tickUpper, tu);
        }
    }

    /// The rounding check again, but after the price has moved and settled somewhere other than 1. Once the price
    /// has settled, nothing trades while the deposit sits in the vault, so no fees blur the result.
    /// Deposits are valued at the TWAP tick, a whole tick, while tokens leave the pool at the exact spot price, which
    /// sits slightly inside a tick. That leaves a sub-tick valuation error of about 1e-8 of the amount, in either
    /// direction. The bound allows 1e-7: anything larger would be a real leak.
    /// forge-config: default.fuzz.runs = 48
    function testFuzz_depositThenWithdraw_afterPriceMove(uint256 a0, uint256 a1, uint256 shock, bool down) public {
        a0 = bound(a0, 0, 1_000 ether);
        a1 = bound(a1, 0, 1_000 ether);
        vm.assume(a0 + a1 >= 1e9);
        shock = bound(shock, 1 ether, 40 ether);
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 60);
        _swap(down, shock);
        _hold(6 minutes);
        _rollHeld(); // two settlements so the epoch mark reflects the new price
        _rollHeld();

        uint256 depId = hook.openBatch();
        _deposit(alice, a0, a1);
        _roll(); // no swaps from here on: spot and TWAP already agree
        vm.prank(alice);
        (uint256 got,,) = hook.claim(depId);
        uint256 wId = hook.openBatch();
        vm.prank(alice);
        hook.requestWithdraw(got);
        _roll();
        vm.prank(alice);
        (, uint256 o0, uint256 o1) = hook.claim(wId);

        uint160 px = SuretyMath.sqrtAtTick(hook.twapTick(5 minutes));
        uint256 valueIn = ScoreLib.value(a0, a1, px);
        uint256 valueOut = ScoreLib.value(o0, o1, px);
        assertLe(valueOut, valueIn + valueIn / 1e7 + 1e6, "never more than went in, beyond sub-tick dust");
        assertGe(valueOut + valueIn / 1e7 + 1e6, valueIn, "and never less, beyond sub-tick dust");
        _assertClaimsMatch();
    }

    function _rollHeld() internal {
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        vm.prank(keeper);
        hook.settle();
    }
}
