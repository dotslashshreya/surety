// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {ScoreLib} from "./ScoreLib.sol";

/// @title SuretyMath
/// @notice Deployed (linked) library holding the hook's heavy math: tick conversion, position valuation, liquidity
///         sizing and the benchmark.
/// @dev Public functions are called with DELEGATECALL, so their bytecode lives here and not in SuretyHook. This keeps
///      the hook under the 24,576-byte deploy limit (EIP-170). Each call costs a little gas: about 2.6k for the first
///      (cold) call in a transaction, then about 100 plus ABI encoding.
library SuretyMath {
    function sqrtAtTick(int24 tick) public pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function tickAtSqrt(uint160 sqrtP) public pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtP);
    }

    /// @notice Value in token1 at `sqrtP` of `liquidity` in [tickLower, tickUpper], plus loose tokens (extra0, extra1).
    function positionValue(
        uint160 sqrtP,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 extra0,
        uint256 extra1
    ) public pure returns (uint256) {
        (uint256 p0, uint256 p1) = ScoreLib.amountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        return ScoreLib.value(p0 + extra0, p1 + extra1, sqrtP);
    }

    /// @notice Value at `sqrtP` of `owner`'s live position (tickLower, tickUpper, salt) in the pool, including its
    ///         uncollected fees, plus loose tokens. Reads the PoolManager's storage directly.
    function livePositionValue(
        IPoolManager manager,
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 extra0,
        uint256 extra1,
        uint160 sqrtP
    ) public view returns (uint256) {
        (uint128 liq, uint256 last0, uint256 last1) =
            StateLibrary.getPositionInfo(manager, poolId, owner, tickLower, tickUpper, salt);
        (uint256 in0, uint256 in1) = StateLibrary.getFeeGrowthInside(manager, poolId, tickLower, tickUpper);
        return positionValue(
            sqrtP,
            tickLower,
            tickUpper,
            liq,
            extra0 + ScoreLib.feesOwed(liq, in0, last0),
            extra1 + ScoreLib.feesOwed(liq, in1, last1)
        );
    }

    /// @notice Largest liquidity in [tickLower, tickUpper] that (amount0, amount1) can fund at `sqrtP`.
    function liquidityFor(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1)
        public
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );
    }

    /// @notice See ScoreLib.benchmark.
    function benchmark(uint256 v0, uint160 sqrtP0, uint160 sqrtP1, uint256 dg0, uint256 dg1)
        public
        pure
        returns (uint256)
    {
        return ScoreLib.benchmark(v0, sqrtP0, sqrtP1, dg0, dg1);
    }
}
