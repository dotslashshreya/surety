// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice Registers the broadcaster as a curator with a bond, and sets a range centred on the 5-minute TWAP.
///         Run once per curator, under that curator's own key. Reads deployments/<chainId>.json.
///
///   forge script script/RegisterCurator.s.sol --sig "run(uint256,int24)" <bond in token1 wei> <half width in ticks> \
///     --rpc-url <rpc> --account surety-careful --broadcast
contract RegisterCurator is Script {
    int24 constant SPACING = 60;

    function run(uint256 bond, int24 halfWidth) external {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        SuretyHook hook = SuretyHook(vm.parseJsonAddress(json, ".hook"));
        (, Currency token1,,,) = hook.poolKey();

        // Centre on the TWAP tick, rounded down to the tick spacing (towards negative infinity).
        int24 t = hook.twapTick(5 minutes);
        int24 centre = (t / SPACING) * SPACING;
        if (t < 0 && t % SPACING != 0) centre -= SPACING;

        vm.startBroadcast();
        IERC20(Currency.unwrap(token1)).approve(address(hook), bond);
        hook.registerCurator(bond);
        hook.setRange(centre - halfWidth, centre + halfWidth);
        vm.stopBroadcast();

        console2.log(
            string.concat("Range: ticks ", vm.toString(centre - halfWidth), " to ", vm.toString(centre + halfWidth))
        );
    }
}
