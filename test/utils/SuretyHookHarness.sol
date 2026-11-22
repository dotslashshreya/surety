// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SuretyHook} from "../../src/SuretyHook.sol";
import {SuretyMath} from "../../src/libraries/SuretyMath.sol";
import {TwapLib} from "../../src/libraries/TwapLib.sol";

/// @notice Test-only subclass exposing internals. The production hook keeps these out to stay under 24 KB.
contract SuretyHookHarness is SuretyHook {
    /// @dev Marks this as a test contract, so `forge build --sizes` doesn't hold it to the 24 KB deploy limit.
    bool public constant IS_TEST = true;

    constructor(IPoolManager pm, Config memory cfg) SuretyHook(pm, cfg) {}

    function curatorAt(uint8 i) external view returns (Curator memory) {
        return curators[i];
    }

    function batchAt(uint256 id) external view returns (Batch memory) {
        return batches[id];
    }

    function sliceValue(uint8 i, uint160 sqrtP) external view returns (uint256) {
        return _sliceValue(i, sqrtP);
    }

    /// @dev Test-only: set a slice's starting value to put it a chosen distance from its benchmark.
    function setV0(uint8 i, uint256 v0) external {
        curators[i].v0 = v0;
    }

    /// @dev Slice value and benchmark right now, exactly as the breaker computes them.
    function liveScore(uint8 i) external view returns (uint256 v, uint256 b) {
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthGlobals(poolManager, poolKey.toId());
        return _liveScore(i, SuretyMath.sqrtAtTick(TwapLib.meanTick(twap, config.shortTwapWindow)), fg0, fg1);
    }

    /// @dev Depositor-owned value at any price (the production view uses the epoch mark).
    function navAt(uint160 sqrtP) external view returns (uint256) {
        return _nav(sqrtP);
    }

    function pendingShift() external view returns (uint8 from, uint8 to) {
        return (shiftFrom, shiftTo);
    }
}
