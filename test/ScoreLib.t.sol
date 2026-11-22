// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ScoreLib} from "../src/libraries/ScoreLib.sol";

/// @notice Unit tests of the benchmark math against hand calculations.
contract ScoreLibTest is Test {
    uint160 constant P1X = uint160(1 << 96); // sqrt price for P = 1
    uint160 constant P4X = uint160(2 << 96); // sqrt price for P = 4

    function test_value_atPriceOne() public pure {
        assertEq(ScoreLib.value(3 ether, 5 ether, P1X), 8 ether);
    }

    function test_value_atPriceFour() public pure {
        // 3 token0 at P=4 is worth 12 token1.
        assertEq(ScoreLib.value(3 ether, 5 ether, P4X), 17 ether);
    }

    function test_benchmark_noMoveNoFees_isV0() public pure {
        assertEq(ScoreLib.benchmark(123 ether, P1X, P1X, 0, 0), 123 ether);
    }

    /// Hand calculation: V0 = 200 at P0 = 1, so L_b = 200 / (2·1) = 100.
    /// P1 = 4: marked value = 200·√4 = 400.
    /// Δg0 = 1% of 2^128 → fees0 = 100·0.01 = 1 token0, worth 4 at P1. Δg1 = 2% → fees1 = 2.
    /// B = 400 + 4 + 2 = 406.
    function test_benchmark_handCalculation() public pure {
        uint256 q128 = uint256(1) << 128;
        uint256 b = ScoreLib.benchmark(200 ether, P1X, P4X, q128 / 100, q128 / 50);
        assertApproxEqAbs(b, 406 ether, 10, "benchmark");
        assertGe(b, 406 ether - 2, "rounds up, in depositors' favour");
    }

    /// The closed form V0·√(P1/P0) must match a real full-range position's value.
    function test_benchmark_matchesFullRangePosition() public pure {
        uint256 v0 = 1000 ether;
        uint160 sqrtP0 = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtP1 = TickMath.getSqrtPriceAtTick(4055); // ~1.5x
        uint128 lb = uint128(v0 / 2); // L = V0 / (2·√P0), √P0 = 1
        (uint256 a0, uint256 a1) = ScoreLib.amountsForLiquidity(
            sqrtP1, TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60)), TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60)), lb
        );
        uint256 actual = ScoreLib.value(a0, a1, sqrtP1);
        uint256 closedForm = ScoreLib.benchmark(v0, sqrtP0, sqrtP1, 0, 0);
        // Full range is not quite infinite, so allow 0.0001%.
        assertApproxEqRel(actual, closedForm, 1e12);
    }

    function test_feesOwed_wraps() public pure {
        uint256 q128 = uint256(1) << 128;
        // Growth wrapped past zero: last = 2^256 - 2^128, now = 0, so the true delta is exactly 2^128.
        uint256 last = type(uint256).max - q128 + 1;
        assertEq(ScoreLib.feesOwed(1 ether, 0, last), 1 ether);
        assertEq(ScoreLib.feesOwed(1 ether, q128 * 2, 0), 2 ether);
    }
}
