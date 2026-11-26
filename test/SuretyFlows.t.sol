// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice Success paths not covered elsewhere.
contract SuretyFlowsTest is SuretyBase {
    /// topUpBond adds to the bond (held as claims) and raises the curator's capital cap.
    function test_topUpBond_raisesBondAndCap() public {
        _bootstrap();
        uint256 claimsBefore = poolManager.balanceOf(address(hook), currency1.toId());
        vm.prank(reckless);
        hook.topUpBond(5 ether);
        (uint256 bond,,,) = hook.curatorState(reckless);
        assertEq(bond, 25 ether);
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()) - claimsBefore, 5 ether, "held as claims");
        _assertClaimsMatch();

        // The cap is now 250. New money arrives and the slice may grow past its old 200 cap.
        _deposit(bob, 200 ether, 200 ether);
        _roll();
        assertGt(hook.sliceValue(1, hook.markSqrtPrice()), 200 ether, "cap raised with the bond");
        assertLe(hook.sliceValue(1, hook.markSqrtPrice()), 250 ether + 1e6);
    }

    /// Exact-output swaps go through the hook like exact-input ones: TWAP updated, breaker looked at, books intact.
    function test_exactOutputSwap_throughHook() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 60);
        uint256 b1 = token1.balanceOf(address(this));
        swapRouter.swapTokensForExactTokens({
            amountOut: 1 ether,
            amountInMax: 2 ether,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: vm.getBlockTimestamp() + 1
        });
        assertEq(token1.balanceOf(address(this)) - b1, 1 ether, "received exactly the amount asked for");
        assertLt(_tick(), 0);
        assertEq(hook.lastBreakerCheck(), vm.getBlockTimestamp(), "afterSwap ran");
        _assertClaimsMatch();
    }

    /// The last depositor can leave completely, and a new depositor then starts fresh at a share price of 1.
    function test_lastDepositorLeaves_thenFreshDeposit() public {
        _bootstrap();
        uint256 id = hook.openBatch();
        vm.prank(alice);
        hook.requestWithdraw(200 ether);
        _roll();
        vm.prank(alice);
        (, uint256 o0, uint256 o1) = hook.claim(id);
        assertApproxEqAbs(o0 + o1, 200 ether, 1e6, "got everything back");
        assertEq(shares.totalSupply(), 0);
        (,, uint256 sharePrice) = hook.epochInfo();
        assertEq(sharePrice, 1e18, "empty vault quotes a share price of 1");
        assertEq(hook.curatorAt(0).liquidity + hook.curatorAt(1).liquidity, 0, "every slice emptied");
        assertEq(hook.anchorLiquidity(), 0, "anchor emptied");

        uint256 id2 = hook.openBatch();
        _deposit(bob, 10 ether, 10 ether);
        _roll();
        vm.prank(bob);
        (uint256 got,,) = hook.claim(id2);
        assertEq(got, 20 ether);
        _assertClaimsMatch();
    }

    /// When a curator leaves and reclaims its bond, its slot can be taken by a new curator.
    function test_freedCuratorSlot_isReused() public {
        _bootstrap();
        vm.prank(reckless);
        hook.exitCurator();
        _roll();
        _roll();
        vm.prank(reckless);
        hook.claimBond();
        assertEq(hook.curatorAt(1).owner, address(0), "slot freed");

        _register(bob, 10 ether, -600, 600);
        assertEq(hook.curatorAt(1).owner, bob, "new curator took the freed slot");
        _deposit(alice, 20 ether, 20 ether);
        _roll();
        assertTrue(hook.curatorAt(1).active);
        assertGt(hook.curatorAt(1).liquidity, 0);
        _assertClaimsMatch();
    }

    function test_curatorState_forNonCurator_isEmpty() public {
        _bootstrap();
        (uint256 bond, uint256 capital, int256 excess, bool frozen) = hook.curatorState(bob);
        assertEq(bond + capital, 0);
        assertEq(excess, 0);
        assertFalse(frozen);
        (bond, capital, excess, frozen) = hook.curatorState(address(0));
        assertEq(bond + capital, 0);
    }
}
