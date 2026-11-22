// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SuretyHook} from "../../src/SuretyHook.sol";

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

    function pendingShift() external view returns (uint8 from, uint8 to) {
        return (shiftFrom, shiftTo);
    }
}
