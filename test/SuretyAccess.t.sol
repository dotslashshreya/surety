// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHookHarness} from "./utils/SuretyHookHarness.sol";
import {SuretyHook} from "../src/SuretyHook.sol";
import {SuretyShares} from "../src/SuretyShares.sol";

/// @notice Failure paths: access control, bad parameters, missing approvals, double claims.
contract SuretyAccessTest is SuretyBase {
    // ---------------------------------------------------------------- access control

    /// Only the hook may mint, burn or move vault shares. If this broke, anyone could print shares.
    function test_shares_onlyHookCanMintBurnMove() public {
        _bootstrap();
        vm.expectRevert(SuretyShares.OnlyVault.selector);
        shares.mint(bob, 1 ether);
        vm.expectRevert(SuretyShares.OnlyVault.selector);
        shares.burn(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(SuretyShares.OnlyVault.selector);
        shares.move(alice, bob, 1 ether);
        assertEq(shares.balanceOf(bob), 0);
        assertEq(shares.balanceOf(alice), 200 ether);
    }

    /// unlockCallback moves money (bond refunds, reallocation); only the PoolManager may call it.
    function test_unlockCallback_onlyPoolManager() public {
        _bootstrap();
        bytes memory steal = abi.encode(SuretyHook.Op.Unbond, abi.encode(address(this), uint256(20 ether)));
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(steal);
        vm.prank(careful); // not even a curator can call it directly
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(SuretyHook.Op.Realloc, abi.encode(careful)));
    }

    /// The hook's pool callbacks run enforcement and the breaker; only the PoolManager may call them.
    function test_hookCallbacks_onlyPoolManager() public {
        SwapParams memory sp =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        ModifyLiquidityParams memory mp =
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1 ether, salt: 0});

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), poolKey, Constants.SQRT_PRICE_1_1);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, sp, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(address(this), poolKey, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), poolKey, mp, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), poolKey, mp, "");
    }

    /// Nobody but the hook can add or remove liquidity in its pool.
    function test_outsideAddAndRemoveLiquidity_rejectedByHook() public {
        _bootstrap();
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(poolManager);
        vm.expectRevert(_hookError(IHooks.beforeAddLiquidity.selector, SuretyHook.LiquidityOnlyThroughVault.selector));
        router.modifyLiquidity(poolKey, ModifyLiquidityParams(-600, 600, 1 ether, 0), "");
        vm.expectRevert(
            _hookError(IHooks.beforeRemoveLiquidity.selector, SuretyHook.LiquidityOnlyThroughVault.selector)
        );
        router.modifyLiquidity(poolKey, ModifyLiquidityParams(-600, 600, -1 ether, 0), "");
    }

    /// The hook binds to the first pool initialized with it and rejects any other.
    function test_secondPool_rejected() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(_hookError(IHooks.beforeInitialize.selector, SuretyHook.PoolAlreadyBound.selector));
        poolManager.initialize(other, Constants.SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- bad parameters

    function test_zeroAmounts_revert() public {
        _bootstrap();
        vm.prank(alice);
        vm.expectRevert(SuretyHook.ZeroAmount.selector);
        hook.deposit(0, 0);
        vm.prank(alice);
        vm.expectRevert(SuretyHook.ZeroAmount.selector);
        hook.requestWithdraw(0);
        vm.prank(careful);
        vm.expectRevert(SuretyHook.ZeroAmount.selector);
        hook.topUpBond(0);
    }

    /// Before its pool exists, a hook accepts no deposits, curators or settlements.
    function test_beforePoolExists_reverts() public {
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144)
        );
        deployCodeTo("SuretyHookHarness.sol:SuretyHookHarness", abi.encode(poolManager, defaultConfig()), flags);
        SuretyHookHarness unbound = SuretyHookHarness(flags);

        vm.startPrank(alice);
        vm.expectRevert(SuretyHook.PoolNotBound.selector);
        unbound.deposit(1 ether, 1 ether);
        vm.expectRevert(SuretyHook.PoolNotBound.selector);
        unbound.registerCurator(1 ether);
        vm.expectRevert(SuretyHook.PoolNotBound.selector);
        unbound.settle();
        vm.stopPrank();
    }

    function test_claim_unprocessedBatch_reverts() public {
        _deposit(alice, 1 ether, 1 ether);
        vm.prank(alice);
        vm.expectRevert(SuretyHook.BatchNotProcessed.selector);
        hook.claim(1);
        vm.prank(alice);
        vm.expectRevert(SuretyHook.BatchNotProcessed.selector);
        hook.claim(99);
    }

    function test_topUpBond_nonCurator_reverts() public {
        vm.prank(bob);
        vm.expectRevert(SuretyHook.NotCurator.selector);
        hook.topUpBond(1 ether);
    }

    /// A curator can't move its range while the price is far from the 5-minute TWAP: nobody can push the price and
    /// make a curator re-add liquidity at it.
    function test_setRange_blockedWhenSpotFarFromTwap() public {
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 60);
        _swap(true, 80 ether);
        vm.prank(careful);
        vm.expectRevert(SuretyHook.SpotDeviation.selector);
        hook.setRange(-1200, 1200);
    }

    // ---------------------------------------------------------------- double claims

    /// Claiming the same batch twice pays once: the second claim returns nothing and moves nothing.
    function test_claimTwice_paysOnce() public {
        _deposit(alice, 100 ether, 100 ether);
        _register(careful, 20 ether, -6000, 6000);
        _roll();
        vm.prank(alice);
        (uint256 first,,) = hook.claim(1);
        assertEq(first, 200 ether);
        vm.prank(alice);
        (uint256 again, uint256 a0, uint256 a1) = hook.claim(1);
        assertEq(again + a0 + a1, 0, "second deposit claim pays nothing");
        assertEq(shares.balanceOf(alice), 200 ether);

        uint256 id = hook.openBatch();
        vm.prank(alice);
        hook.requestWithdraw(50 ether);
        _roll();
        vm.prank(alice);
        (, uint256 w0, uint256 w1) = hook.claim(id);
        assertGt(w0 + w1, 0);
        uint256 b0 = token0.balanceOf(alice);
        uint256 b1 = token1.balanceOf(alice);
        vm.prank(alice);
        (, uint256 x0, uint256 x1) = hook.claim(id);
        assertEq(x0 + x1, 0, "second withdrawal claim pays nothing");
        assertEq(token0.balanceOf(alice), b0);
        assertEq(token1.balanceOf(alice), b1);
        _assertClaimsMatch();
    }

    /// Someone who queued nothing in a batch gets nothing from it.
    function test_claim_withoutRequest_paysNothing() public {
        _bootstrap();
        vm.prank(bob);
        (uint256 s, uint256 o0, uint256 o1) = hook.claim(1);
        assertEq(s + o0 + o1, 0);
        assertEq(shares.balanceOf(bob), 0);
    }

    // ---------------------------------------------------------------- missing approvals and balances

    function test_deposit_withoutApproval_reverts() public {
        address u = _freshUser("noApproval");
        vm.prank(u);
        vm.expectRevert(stdError.arithmeticError); // the token's allowance check underflows
        hook.deposit(1 ether, 1 ether);
    }

    function test_deposit_withoutBalance_reverts() public {
        address u = makeAddr("broke");
        vm.startPrank(u);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.expectRevert(stdError.arithmeticError); // the token's balance check underflows
        hook.deposit(1 ether, 1 ether);
        vm.stopPrank();
    }

    function test_registerCurator_withoutApproval_reverts() public {
        address u = _freshUser("curatorNoApproval");
        vm.prank(u);
        vm.expectRevert(stdError.arithmeticError);
        hook.registerCurator(1 ether);
        assertEq(hook.curatorAt(0).owner, address(0), "nothing was registered");
    }

    function test_topUpBond_withoutApproval_reverts() public {
        address u = _freshUser("topUpNoApproval");
        vm.startPrank(u);
        token1.approve(address(hook), 1 ether); // exactly the bond, nothing more
        hook.registerCurator(1 ether);
        vm.expectRevert(stdError.arithmeticError);
        hook.topUpBond(1 ether);
        vm.stopPrank();
        assertEq(hook.curatorAt(0).bond, 1 ether);
    }

    function test_requestWithdraw_moreThanOwned_reverts() public {
        _bootstrap();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 200 ether, 201 ether)
        );
        hook.requestWithdraw(201 ether);
    }
}
