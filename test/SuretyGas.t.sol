// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {SuretyBase} from "./utils/SuretyBase.sol";

/// @notice Gas for the README table, written to snapshots/surety-gas.json.
/// @dev Each test makes exactly one measured call and does its preparation only through cheatcodes, so storage is
///      as cold as in a real transaction. setUp runs as a separate transaction.
contract SuretyGasTest is SuretyBase {
    using EasyPosm for IPositionManager;

    PoolKey plainKey;

    function setUp() public override {
        super.setUp();
        _bootstrap();
        vm.warp(vm.getBlockTimestamp() + 60);
        _swap(true, 1 ether); // the breaker check last ran now

        // Baseline: the same pair and fee with no hook, and comparable full-range liquidity.
        plainKey = PoolKey(currency0, currency1, FEE, SPACING, IHooks(address(0)));
        poolManager.initialize(plainKey, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            plainKey,
            TickMath.minUsableTick(SPACING),
            TickMath.maxUsableTick(SPACING),
            100 ether,
            type(uint256).max,
            type(uint256).max,
            address(this),
            vm.getBlockTimestamp() + 1,
            ""
        );
    }

    function _swapOn(PoolKey memory key, bool zeroForOne) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: 0.1 ether,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: vm.getBlockTimestamp() + 1
        });
    }

    function test_gas_swap_noHookBaseline() public {
        _swapOn(plainKey, false);
        vm.snapshotGasLastCall("surety-gas", "swap_noHook_baseline");
    }

    /// The common case: the breaker checked less than 12 s ago, so this swap only updates the TWAP.
    function test_gas_swap_breakerSkipped() public {
        vm.warp(vm.getBlockTimestamp() + 5);
        _swapOn(poolKey, false);
        vm.snapshotGasLastCall("surety-gas", "swap_breakerCheckSkipped");
    }

    /// Every 12 s in a quiet market: the throttle lets the swap look, but spot is still within 20 ticks of the TWAP the
    /// last full check used, so the gate skips the valuation.
    function test_gas_swap_breakerGateSkips() public {
        vm.warp(vm.getBlockTimestamp() + 13);
        _swapOn(poolKey, false);
        vm.snapshotGasLastCall("surety-gas", "swap_breakerGateSkips");
        assertLt(hook.lastFullCheck(), vm.getBlockTimestamp(), "no full check");
    }

    /// When the price has moved, or 5 minutes after the last one: the swap values every slice against its benchmark.
    function test_gas_swap_breakerFullCheck() public {
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1);
        _swapOn(poolKey, false);
        vm.snapshotGasLastCall("surety-gas", "swap_breakerFullCheck_noTrip");
        assertEq(hook.lastFullCheck(), vm.getBlockTimestamp(), "full check ran");
    }

    /// Once per epoch: the first swap after it ends scores, slashes and pays fees (plus a breaker check).
    function test_gas_swap_runsEnforcement() public {
        vm.warp(hook.epochEnd());
        _swapOn(poolKey, false);
        vm.snapshotGasLastCall("surety-gas", "swap_runsEpochEnforcement");
    }

    /// Rare: the check finds a slice more than 5% behind and pulls its liquidity out of the pool.
    function test_gas_swap_tripsBreaker() public {
        (uint256 v,) = hook.liveScore(1);
        hook.setV0(1, v * 10_000 / 9_000); // 10% behind its benchmark
        vm.cool(address(hook));
        vm.warp(vm.getBlockTimestamp() + 5 minutes + 1);
        _swapOn(poolKey, false);
        vm.snapshotGasLastCall("surety-gas", "swap_tripsBreaker");
        assertTrue(hook.curatorAt(1).frozen);
    }

    /// Once per epoch, by anyone: enforcement (if no swap did it) plus the full reallocation.
    function test_gas_settle_withReallocation() public {
        vm.warp(hook.epochEnd());
        vm.prank(keeper);
        hook.settle();
        vm.snapshotGasLastCall("surety-gas", "settle_enforceAndReallocate");
    }
}
