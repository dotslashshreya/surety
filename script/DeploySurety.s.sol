// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Deployers} from "../test/utils/Deployers.sol";
import {SuretyHook} from "../src/SuretyHook.sol";
import {Faucet} from "../src/demo/Faucet.sol";

/// @notice Deploys the Surety demo: tokens and faucet, the hook at a mined address, the mETH/mUSDC pool at about
///         3,000, a seed deposit, and bond money for the two curators. Writes every address to
///         deployments/<chainId>.json for the curator script, the bots and the dashboard.
///
///   Local:   CAREFUL=0x.. RECKLESS=0x.. forge script script/DeploySurety.s.sol --rpc-url http://127.0.0.1:8545 \
///              --private-key <anvil key 0> --broadcast
///   Testnet: CAREFUL=0x.. RECKLESS=0x.. forge script script/DeploySurety.s.sol --rpc-url <unichain sepolia> \
///              --account surety-deployer --broadcast
contract DeploySurety is Script, Deployers {
    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    int24 constant TICK_AT_3000 = 80067; // 1.0001^80067 ≈ 3,000

    /// @dev On Anvil, Permit2 is placed at its canonical address with anvil_setCode.
    function _etch(address target, bytes memory bytecode) internal override {
        require(block.chainid == 31337, "etch: local Anvil only");
        vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '","', vm.toString(bytecode), '"]'));
    }

    function run() external {
        bool local = block.chainid == 31337;
        require(local || block.chainid == 1301, "Local Anvil (31337) or Unichain Sepolia (1301) only");
        address careful = vm.envAddress("CAREFUL");
        address reckless = vm.envAddress("RECKLESS");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        deployArtifacts(); // local: deploys Permit2, PoolManager, PositionManager, router; testnet: the live ones

        Faucet faucet = new Faucet(deployer);
        bool methIs0 = address(faucet.meth()) < address(faucet.musdc());
        (Currency c0, Currency c1) = methIs0
            ? (Currency.wrap(address(faucet.meth())), Currency.wrap(address(faucet.musdc())))
            : (Currency.wrap(address(faucet.musdc())), Currency.wrap(address(faucet.meth())));

        // The hook's address must carry its permission bits: mine a CREATE2 salt for it.
        SuretyHook.Config memory cfg = _config(local, methIs0);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory args = abi.encode(poolManager, cfg);
        (address mined, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, flags, type(SuretyHook).creationCode, args);
        SuretyHook hook = new SuretyHook{salt: salt}(poolManager, cfg);
        require(address(hook) == mined, "hook address mismatch");

        PoolKey memory key = PoolKey(c0, c1, FEE, SPACING, IHooks(address(hook)));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(methIs0 ? TICK_AT_3000 : -TICK_AT_3000));

        // Seed the vault: about $200k locally, about $6M on testnet.
        (uint256 seedMeth, uint256 seedMusdc) = local ? (33.333333 ether, 100_000 ether) : (1_000 ether, 3_000_000 ether);
        faucet.ownerMint(deployer, seedMeth, seedMusdc);
        IERC20(address(faucet.meth())).approve(address(hook), seedMeth);
        IERC20(address(faucet.musdc())).approve(address(hook), seedMusdc);
        (uint256 a0, uint256 a1) = methIs0 ? (seedMeth, seedMusdc) : (seedMusdc, seedMeth);
        hook.deposit(a0, a1);

        // Bond money for the curators (bonds are in token1). Careful at about twice what its slice needs.
        (uint256 carefulUsd, uint256 recklessUsd) = local ? (18_000, 9_000) : (540_000, 270_000);
        _fundBond(faucet, careful, carefulUsd, methIs0);
        _fundBond(faucet, reckless, recklessUsd, methIs0);
        vm.stopBroadcast();

        _write(faucet, hook, deployer, careful, reckless, methIs0);
        console2.log("SuretyHook:", address(hook));
        console2.log("Faucet:    ", address(faucet));
        console2.log("mETH is token0:", methIs0);
    }

    /// @dev Parameters from the spec: local video vs testnet. Bond amounts are in token1.
    function _config(bool local, bool methIs0) internal pure returns (SuretyHook.Config memory) {
        return SuretyHook.Config({
            epochLength: local ? 30 minutes : 15 minutes,
            perfFeeBps: 2000,
            reallocBps: 2500,
            bondMultiple: 10,
            settleRewardBps: 500,
            minWidth: 10 * SPACING,
            maxDistance: 1000,
            maxRebalances: 3,
            shortTwapWindow: 5 minutes,
            maxSpotDeviation: 500,
            breakerBps: 500,
            breakerInterval: 12,
            anchorBps: 1000,
            minBond: _usdToToken1(100, methIs0),
            maxSettleReward: _usdToToken1(500, methIs0)
        });
    }

    /// @dev Dollars to token1 units: token1 is mUSDC ($1) when mETH is token0, otherwise mETH (~$3,000).
    function _usdToToken1(uint256 usd, bool methIs0) internal pure returns (uint256) {
        return methIs0 ? usd * 1 ether : (usd * 1 ether) / 3000;
    }

    function _fundBond(Faucet faucet, address curator, uint256 usd, bool methIs0) internal {
        uint256 amount = _usdToToken1(usd, methIs0);
        if (methIs0) faucet.ownerMint(curator, 0, amount);
        else faucet.ownerMint(curator, amount, 0);
    }

    function _write(Faucet faucet, SuretyHook hook, address deployer, address careful, address reckless, bool methIs0)
        internal
    {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", block.number);
        vm.serializeAddress(o, "poolManager", address(poolManager));
        vm.serializeAddress(o, "positionManager", address(positionManager));
        vm.serializeAddress(o, "swapRouter", address(swapRouter));
        vm.serializeAddress(o, "permit2", address(permit2));
        vm.serializeAddress(o, "faucet", address(faucet));
        vm.serializeAddress(o, "meth", address(faucet.meth()));
        vm.serializeAddress(o, "musdc", address(faucet.musdc()));
        vm.serializeAddress(o, "shares", address(hook.shares()));
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "careful", careful);
        vm.serializeAddress(o, "reckless", reckless);
        vm.serializeBool(o, "methIsToken0", methIs0);
        string memory json = vm.serializeAddress(o, "hook", address(hook));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
