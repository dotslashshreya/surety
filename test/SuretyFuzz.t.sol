// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SuretyBase} from "./utils/SuretyBase.sol";

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
}
