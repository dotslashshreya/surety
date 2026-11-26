// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice M1 + M2: vault core, queues, curators and guardrails.
contract SuretyVaultTest is SuretyBase {
    // ---------------------------------------------------------------- M1

    function test_boundToOnePool() public {
        assertTrue(hook.poolBound());
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, SuretyHook.PoolAlreadyBound.selector));
        poolManager.initialize(other, Constants.SQRT_PRICE_1_1);
    }

    function test_outsideLiquidityReverts() public {
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(poolManager);
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, SuretyHook.LiquidityOnlyThroughVault.selector));
        router.modifyLiquidity(poolKey, ModifyLiquidityParams(-600, 600, 1 ether, 0), "");
    }

    function test_depositIsQueuedUntilSettlement() public {
        _deposit(alice, 10 ether, 10 ether);
        assertEq(token0.balanceOf(address(hook)), 10 ether, "held as pending ERC20");
        assertEq(shares.totalSupply(), 0, "no shares before boundary");
        vm.expectRevert(SuretyHook.BatchNotProcessed.selector);
        vm.prank(alice);
        hook.claim(1);
    }

    function test_bootstrap_deploysCapitalAndMintsShares() public {
        _bootstrap();
        assertEq(shares.balanceOf(alice), 200 ether, "first deposit priced 1:1 at P=1");
        SuretyHook.Curator memory c = hook.curatorAt(0);
        SuretyHook.Curator memory r = hook.curatorAt(1);
        assertTrue(c.active && r.active);
        assertGt(c.liquidity, 0);
        assertGt(r.liquidity, 0);
        assertEq(token0.balanceOf(address(hook)), 0, "pending ERC20 moved into the pool");
        assertApproxEqAbs(hook.totalValue(), 200 ether, 10, "nav");
        _assertClaimsMatch();
    }

    function test_swapThroughHookLiquidity() public {
        _bootstrap();
        uint256 before = token1.balanceOf(address(this));
        _swap(true, 1 ether);
        assertGt(token1.balanceOf(address(this)), before + 0.9 ether);
        _assertClaimsMatch();
    }

    function test_withdrawRoundTrip() public {
        _bootstrap();
        vm.prank(alice);
        hook.requestWithdraw(50 ether); // a quarter
        _roll();
        uint256 b0 = token0.balanceOf(alice);
        uint256 b1 = token1.balanceOf(alice);
        vm.prank(alice);
        hook.claim(2);
        uint256 got0 = token0.balanceOf(alice) - b0;
        uint256 got1 = token1.balanceOf(alice) - b1;
        assertApproxEqRel(got0 + got1, 50 ether, 1e14, "quarter of value back");
        assertEq(shares.totalSupply(), 150 ether);
        _assertClaimsMatch();
    }

    function test_secondDepositPricedAtNav() public {
        _bootstrap();
        for (uint256 i; i < 10; i++) {
            _swap(i % 2 == 0, 5 ether);
        }
        _deposit(bob, 10 ether, 10 ether);
        _roll();
        vm.prank(bob);
        (uint256 got,,) = hook.claim(2);
        (,, uint256 sharePrice) = hook.epochInfo();
        assertGt(sharePrice, 1e18, "fees raised the share price");
        assertLt(got, 20 ether, "later depositor gets fewer shares per token");
        _assertClaimsMatch();
    }

    // ---------------------------------------------------------------- M2

    function test_registerCurator_holdsBondAsClaims() public {
        vm.prank(careful);
        hook.registerCurator(5 ether);
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()), 5 ether);
        (uint256 bond,,,) = hook.curatorState(careful);
        assertEq(bond, 5 ether);
    }

    function test_registerCurator_rejects() public {
        vm.prank(careful);
        vm.expectRevert(SuretyHook.BondTooSmall.selector);
        hook.registerCurator(0.5 ether);

        vm.startPrank(careful);
        hook.registerCurator(5 ether);
        vm.expectRevert(SuretyHook.AlreadyCurator.selector);
        hook.registerCurator(5 ether);
        vm.stopPrank();

        vm.prank(reckless);
        hook.registerCurator(5 ether);
        vm.prank(bob);
        hook.registerCurator(5 ether);
        vm.prank(keeper);
        vm.expectRevert(SuretyHook.CuratorLimit.selector);
        hook.registerCurator(5 ether);
    }

    function test_setRange_guardrails() public {
        vm.startPrank(careful);
        hook.registerCurator(5 ether);
        vm.expectRevert(SuretyHook.InvalidRange.selector);
        hook.setRange(-240, 240); // narrower than W_min = 600
        vm.expectRevert(SuretyHook.InvalidRange.selector);
        hook.setRange(-301, 299); // not aligned to tick spacing
        vm.expectRevert(SuretyHook.InvalidRange.selector);
        hook.setRange(600, -600); // inverted
        vm.expectRevert(SuretyHook.RangeTooFar.selector);
        hook.setRange(1200, 1800); // centre 1500 ticks from TWAP, D = 1000
        hook.setRange(-600, 600);
        hook.setRange(-1200, 1200);
        hook.setRange(-1800, 1800);
        vm.expectRevert(SuretyHook.TooManyRebalances.selector);
        hook.setRange(-600, 600); // R = 3 per epoch
        vm.stopPrank();
    }

    function test_setRange_movesLiquidityWithoutSwapping() public {
        _bootstrap();
        uint256 navBefore = hook.totalValue();
        vm.prank(careful);
        hook.setRange(-1200, 1200);
        SuretyHook.Curator memory c = hook.curatorAt(0);
        assertEq(c.tickLower, -1200);
        assertGt(c.liquidity, 0);
        assertApproxEqAbs(hook.totalValue(), navBefore, 10, "value unchanged by a range move");
        _assertClaimsMatch();
    }

    function test_nonCuratorCannotSetRange() public {
        vm.expectRevert(SuretyHook.NotCurator.selector);
        hook.setRange(-600, 600);
    }

    function test_capitalCappedAtBondMultiple() public {
        _deposit(alice, 100 ether, 100 ether);
        _register(careful, 5 ether, -6000, 6000); // cap = 50
        _roll();
        assertApproxEqAbs(hook.sliceValue(0, hook.markSqrtPrice()), 50 ether, 10, "slice capped at k x bond");
        assertApproxEqAbs(hook.totalValue() - hook.sliceValue(0, hook.markSqrtPrice()), 150 ether, 10, "rest stays with depositors");
        assertGt(hook.anchorLiquidity(), 0, "and sits full range in the anchor, not idle");
        _assertClaimsMatch();
    }

    function test_exitAndClaimBond() public {
        _bootstrap();
        vm.prank(reckless);
        hook.exitCurator();
        vm.prank(reckless);
        vm.expectRevert(SuretyHook.BondLocked.selector);
        hook.claimBond();

        _roll(); // scored, slice returned
        assertFalse(hook.curatorAt(1).active);
        assertEq(hook.curatorAt(1).liquidity, 0);
        vm.prank(reckless);
        vm.expectRevert(SuretyHook.BondLocked.selector);
        hook.claimBond(); // one more full epoch

        _roll();
        (uint256 bond,,,) = hook.curatorState(reckless);
        uint256 before = token1.balanceOf(reckless);
        vm.prank(reckless);
        hook.claimBond();
        assertEq(token1.balanceOf(reckless) - before, bond);
        _assertClaimsMatch();
    }
}
