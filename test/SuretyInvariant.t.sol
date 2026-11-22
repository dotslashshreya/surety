// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHandler} from "./utils/SuretyHandler.sol";
import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice M6 invariant suite. A handler fires random deposits, withdrawals, claims, swaps, time warps, range moves
///         and settlements at a live pool; after every sequence, these must still hold.
contract SuretyInvariantTest is SuretyBase {
    SuretyHandler handler;

    function setUp() public override {
        super.setUp();
        _bootstrap();
        handler = new SuretyHandler(
            hook, swapRouter, token0, token1, poolKey, [alice, bob], [careful, reckless]
        );
        token0.mint(address(handler), 1_000_000 ether);
        token1.mint(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    /// 1. The hook's ERC-6909 claims equal exactly what its books say it holds.
    function invariant_claimsEqualBooks() public view {
        _assertClaimsMatch();
    }

    /// 2. The hook's plain ERC20 balance is exactly queued deposits plus withdrawals not yet claimed.
    function invariant_erc20EqualsQueuedAndUnclaimed() public view {
        uint256 e0;
        uint256 e1;
        uint256 last = hook.openBatch();
        for (uint256 id = 1; id <= last; id++) {
            SuretyHook.Batch memory b = hook.batchAt(id);
            if (!b.processed) {
                e0 += b.dep0;
                e1 += b.dep1;
            } else {
                e0 += b.out0 - handler.claimed0(id);
                e1 += b.out1 - handler.claimed1(id);
            }
        }
        // Withdrawal claims round down, so a few wei of dust may stay behind; nothing may ever be missing.
        assertGe(token0.balanceOf(address(hook)), e0, "token0 missing");
        assertGe(token1.balanceOf(address(hook)), e1, "token1 missing");
        assertLe(token0.balanceOf(address(hook)), e0 + 1000, "token0 unaccounted");
        assertLe(token1.balanceOf(address(hook)), e1 + 1000, "token1 unaccounted");
    }

    /// 3. Bonds only ever go down (no top-ups here), so no slash can exceed a bond or create value.
    function invariant_bondsNeverIncrease() public view {
        assertLe(hook.curatorAt(0).bond, 20 ether);
        assertLe(hook.curatorAt(1).bond, 20 ether);
    }

    /// 4. The breaker never changes a bond.
    function invariant_breakerNeverTouchesBonds() public view {
        assertFalse(handler.breakerChangedBond());
    }

    /// 5. Settlement happens at most once per epoch.
    function invariant_settleOncePerEpoch() public view {
        assertFalse(handler.settledTwiceInOneEpoch());
    }

    /// 6. After reallocation, every slice is within k × bond.
    function invariant_capitalWithinBondMultiple() public view {
        assertFalse(handler.capBroken());
    }

    /// 7. The epoch clock is consistent.
    function invariant_epochClock() public view {
        assertEq(hook.epochEnd() - hook.epochStart(), EPOCH);
        assertLe(hook.epochStart(), vm.getBlockTimestamp());
    }

    /// Coverage tally: summed over every run in a sequence, so a run that never settles is visible in the log.
    function afterInvariant() external {
        assertGt(handler.calls(), 0, "the handler did something");
        emit log_named_uint("successful settles", handler.settlesOk());
        emit log_named_uint("successful swaps", handler.swapsOk());
        emit log_named_uint("successful claims", handler.claimsOk());
    }
}
