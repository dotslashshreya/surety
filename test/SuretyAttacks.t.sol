// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";
import {ScoreLib} from "../src/libraries/ScoreLib.sol";
import {SuretyMath} from "../src/libraries/SuretyMath.sol";

/// @notice M6 attack tests. Each one ends with the attacker no better off, asserted on balances.
///         The breaker push (griefing) attack is in SuretyBreaker.t.sol.
contract SuretyAttacksTest is SuretyBase {
    // ---------------------------------------------------------------- helpers


    function _shortTwapPrice() internal view returns (uint160) {
        return SuretyMath.sqrtAtTick(hook.twapTick(5 minutes));
    }

    /// @dev What `who` holds, in token1, at `sqrtP`: wallet tokens plus vault shares.
    function _wealth(address who, uint160 sqrtP) internal view returns (uint256) {
        uint256 w = ScoreLib.value(token0.balanceOf(who), token1.balanceOf(who), sqrtP);
        uint256 s = shares.balanceOf(who);
        if (s > 0) w += hook.navAt(sqrtP) * s / shares.totalSupply();
        return w;
    }

    function _swapAs(address who, bool zeroForOne, uint256 amountIn) internal {
        vm.startPrank(who);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: who,
            deadline: vm.getBlockTimestamp() + 1
        });
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- deposit timing

    /// The price falls late in an epoch, so that epoch's average overvalues token0. An attacker deposits only token0,
    /// hoping it is priced at the stale average. Deposits are priced at the short TWAP when settle() runs, so the
    /// shares it gets are worth what it put in, and no more.
    function test_depositTiming_oneSidedDepositAfterTrendDoesNotPay() public {
        _bootstrap();
        vm.warp(hook.epochEnd() - 7 minutes);
        _swap(true, 80 ether); // the late trend
        _hold(6 minutes);

        uint256 batchId = hook.openBatch();
        _deposit(bob, 20 ether, 0);

        vm.warp(hook.epochEnd());
        _hold(1 minutes); // the first swap scores the epoch; the mark becomes the stale epoch average
        vm.prank(keeper);
        hook.settle();
        vm.prank(bob);
        hook.claim(batchId);

        uint160 px = _shortTwapPrice();
        uint256 fair = ScoreLib.value(20 ether, 0, px);
        uint256 stale = ScoreLib.value(20 ether, 0, hook.markSqrtPrice());
        assertGt(stale, fair * 105 / 100, "the stale mark overvalues the deposit by more than 5%");

        uint256 got = hook.navAt(px) * shares.balanceOf(bob) / shares.totalSupply();
        assertLe(got, fair + fair / 1000, "shares worth no more than the deposit at the fair price");
        assertGe(got, fair - fair / 100, "and the depositor isn't short-changed either");
        _assertClaimsMatch();
    }

    // ---------------------------------------------------------------- wash trading

    /// A curator trades back and forth through its own range to inflate the fees its slice earns. It pays every swap
    /// fee from its own wallet and gets back at most φ = 20% of the excess as a performance fee, so it ends poorer,
    /// and depositors keep the difference.
    function test_washTrading_curatorEndsPoorer() public {
        _bootstrap();
        vm.prank(reckless);
        token0.approve(address(swapRouter), type(uint256).max);
        vm.prank(reckless);
        token1.approve(address(swapRouter), type(uint256).max);

        uint160 p0 = _shortTwapPrice();
        uint256 before = _wealth(reckless, p0);
        uint256 navBefore = hook.navAt(p0);

        for (uint256 i; i < 20; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _swapAs(reckless, i % 2 == 0, 3 ether);
        }
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        vm.prank(keeper);
        hook.settle();

        uint160 p1 = _shortTwapPrice();
        assertGt(shares.balanceOf(reckless), 0, "the wash volume did earn a performance fee");
        assertLt(_wealth(reckless, p1), before, "but the curator ends poorer than it started");
        assertGt(hook.navAt(p1), navBefore, "and depositors keep the fees it paid");
        _assertClaimsMatch();
    }

    // ---------------------------------------------------------------- boundary push

    /// Pushing the price in the last seconds of an epoch barely moves the score, because P1 is the average over the
    /// whole epoch. The attacker pays fees and price impact for almost nothing.
    function test_boundaryPush_barelyMovesScore_attackerPoorer() public {
        _bootstrap();
        for (uint256 i; i < 10; i++) {
            vm.warp(vm.getBlockTimestamp() + 2 minutes);
            _swap(i % 2 == 0, 2 ether);
        }
        uint256 snap = vm.snapshotState();

        // Honest end of epoch.
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        vm.prank(keeper);
        hook.settle();
        int256 honest = hook.curatorAt(1).lastExcess;
        uint256 v0 = hook.curatorAt(1).v0;

        // Same epoch, but the attacker pushes the price 12 s before the end and reverses it right after.
        vm.revertToState(snap);
        uint160 pStart = _shortTwapPrice();
        uint256 before = _wealth(address(this), pStart);
        vm.warp(hook.epochEnd() - 12);
        uint256 b0 = token0.balanceOf(address(this));
        _swap(false, 30 ether); // push the price up, buying token0
        uint256 bought = token0.balanceOf(address(this)) - b0;
        vm.warp(hook.epochEnd());
        _swap(true, bought); // reverse: this swap also scores the epoch
        _hold(6 minutes);
        vm.prank(keeper);
        hook.settle();
        int256 pushed = hook.curatorAt(1).lastExcess;

        int256 diff = pushed - honest;
        if (diff < 0) diff = -diff;
        assertLt(uint256(diff), v0 / 200, "score moved by less than 0.5% of the slice");
        assertLt(_wealth(address(this), pStart), before, "the attacker paid for nothing");
        _assertClaimsMatch();
    }

    // ---------------------------------------------------------------- sandwiching the reallocation

    /// To trade against the liquidity settle() is about to add, an attacker must first move the price. settle()
    /// refuses to add liquidity while spot is far from the 5-minute TWAP, so the sandwich never gets its middle.
    function test_sandwichReallocation_blockedBySpotGuard() public {
        _bootstrap();
        _deposit(bob, 20 ether, 20 ether); // gives the next settle() liquidity to add
        vm.warp(hook.epochEnd());
        _hold(1 minutes);
        _swap(true, 80 ether); // front-run leg: more than the 5% band settle() accepts
        vm.prank(keeper);
        vm.expectRevert(SuretyHook.SpotDeviation.selector);
        hook.settle();
    }
}
