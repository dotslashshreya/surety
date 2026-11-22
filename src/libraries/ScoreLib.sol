// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title ScoreLib
/// @notice Valuation and the full-range benchmark used to score curators.
/// @dev All values are in raw token1 units. Prices are Uniswap sqrt prices in Q64.96.
///      Rounding always favours depositors: curator value rounds down, the benchmark rounds up.
library ScoreLib {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Value of (amount0, amount1) in token1 at sqrt price `sqrtP`, rounded down.
    function value(uint256 amount0, uint256 amount1, uint160 sqrtP) internal pure returns (uint256) {
        return amount1 + FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtP, Q96), sqrtP, Q96);
    }

    /// @notice Same as `value`, rounded up.
    function valueUp(uint256 amount0, uint256 amount1, uint160 sqrtP) internal pure returns (uint256) {
        return amount1 + FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(amount0, sqrtP, Q96), sqrtP, Q96);
    }

    /// @notice Token amounts held by `liquidity` in [sqrtA, sqrtB] at price `sqrtP`, rounded down.
    function amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    /// @notice The passive benchmark: a full-range position worth `v0` at P0, marked at P1, plus its fees.
    /// @dev B = V0·√(P1/P0) + L_b·(Δg0·P1 + Δg1)/2^128, with L_b = V0 / (2·√P0).
    ///      Δg0/Δg1 are the changes in the pool's feeGrowthGlobal over the epoch. A full-range position's boundary
    ///      ticks are never crossed, so its fee growth inside changes exactly as the global figure does.
    function benchmark(uint256 v0, uint160 sqrtP0, uint160 sqrtP1, uint256 dg0, uint256 dg1)
        internal
        pure
        returns (uint256)
    {
        if (v0 == 0) return 0;
        uint256 marked = FullMath.mulDivRoundingUp(v0, sqrtP1, sqrtP0);
        uint256 lb = FullMath.mulDivRoundingUp(v0, Q96, 2 * uint256(sqrtP0));
        uint256 fees0 = FullMath.mulDivRoundingUp(lb, dg0, Q128);
        uint256 fees1 = FullMath.mulDivRoundingUp(lb, dg1, Q128);
        return marked + valueUp(fees0, fees1, sqrtP1);
    }

    /// @notice Fees owed to a position since its last checkpoint, rounded down.
    function feesOwed(uint128 liquidity, uint256 insideNow, uint256 insideLast) internal pure returns (uint256) {
        uint256 delta;
        unchecked {
            delta = insideNow - insideLast; // fee growth is allowed to wrap
        }
        return FullMath.mulDiv(delta, liquidity, Q128);
    }
}
