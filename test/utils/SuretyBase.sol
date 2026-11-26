// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./BaseTest.sol";
import {SuretyHookHarness} from "./SuretyHookHarness.sol";
import {SuretyHook} from "../../src/SuretyHook.sol";
import {SuretyShares} from "../../src/SuretyShares.sol";

abstract contract SuretyBase is BaseTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 3000;
    int24 constant SPACING = 60;
    uint32 constant EPOCH = 30 minutes;

    Currency currency0;
    Currency currency1;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;
    SuretyHookHarness hook;
    SuretyShares shares;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address careful = makeAddr("careful");
    address reckless = makeAddr("reckless");
    address keeper = makeAddr("keeper");

    function defaultConfig() internal pure returns (SuretyHook.Config memory) {
        return SuretyHook.Config({
            epochLength: EPOCH,
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
            minBond: 1 ether,
            maxSettleReward: 10 ether
        });
    }

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("SuretyHookHarness.sol:SuretyHookHarness", abi.encode(poolManager, defaultConfig()), flags);
        hook = SuretyHookHarness(flags);
        shares = hook.shares();
        vm.label(flags, "SuretyHook");

        poolKey = PoolKey(currency0, currency1, FEE, SPACING, IHooks(address(hook)));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        address[5] memory users = [alice, bob, careful, reckless, keeper];
        for (uint256 i; i < users.length; i++) {
            token0.mint(users[i], 1_000_000 ether);
            token1.mint(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            token0.approve(address(hook), type(uint256).max);
            token1.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deposit(address who, uint256 a0, uint256 a1) internal {
        vm.prank(who);
        hook.deposit(a0, a1);
    }

    function _register(address who, uint256 bond, int24 tl, int24 tu) internal {
        vm.startPrank(who);
        hook.registerCurator(bond);
        hook.setRange(tl, tu);
        vm.stopPrank();
    }

    function _warpToEpochEnd() internal {
        vm.warp(hook.epochEnd());
    }

    /// @dev End the current epoch and settle it from `keeper`.
    function _roll() internal {
        _warpToEpochEnd();
        vm.prank(keeper);
        hook.settle();
    }

    /// @dev Standard setup: alice deposits, two curators register, first settlement deploys the capital.
    function _bootstrap() internal {
        _deposit(alice, 100 ether, 100 ether);
        _register(careful, 20 ether, -6000, 6000);
        _register(reckless, 20 ether, -300, 300);
        _roll();
        vm.prank(alice);
        hook.claim(1);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: vm.getBlockTimestamp() + 1
        });
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    /// @dev Hold the current price for `secs`, with a tiny swap every 30 s so the TWAP records it.
    function _hold(uint256 secs) internal {
        uint256 end = vm.getBlockTimestamp() + secs;
        bool dir;
        while (vm.getBlockTimestamp() < end) {
            vm.warp(vm.getBlockTimestamp() + 30);
            _swap(dir, 1e12);
            dir = !dir;
        }
    }

    /// @dev Whether an event with this signature was recorded since vm.recordLogs().
    function _sawEvent(bytes32 sig) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) return true;
        }
        return false;
    }

    /// @dev The exact revert the PoolManager raises when the hook rejects one of its callbacks with `err`.
    function _hookError(bytes4 callback, bytes4 err) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(err),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev A user holding both tokens but with no approvals given to anyone.
    function _freshUser(string memory name) internal returns (address u) {
        u = makeAddr(name);
        token0.mint(u, 1_000 ether);
        token1.mint(u, 1_000 ether);
    }

    /// @dev Core accounting check: the hook's ERC-6909 claims equal exactly what its books say it holds.
    function _assertClaimsMatch() internal view {
        (uint256 c0, uint256 c1) = hook.accountedClaims();
        assertEq(poolManager.balanceOf(address(hook), currency0.toId()), c0, "claims0 != books");
        assertEq(poolManager.balanceOf(address(hook), currency1.toId()), c1, "claims1 != books");
    }
}
