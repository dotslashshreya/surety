// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {SuretyHookHarness} from "./SuretyHookHarness.sol";
import {SuretyHook} from "../../src/SuretyHook.sol";
import {SuretyShares} from "../../src/SuretyShares.sol";

/// @notice Random actions against a live Surety pool for the invariant suite. Every failure is expected and swallowed
///         (fail_on_revert = false); what matters is the state left behind.
contract SuretyHandler is CommonBase, StdUtils, StdCheats {
    SuretyHookHarness public hook;
    SuretyShares public shares;
    IUniswapV4Router04 public router;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public key;

    address[2] public depositors;
    address[2] public curatorAddrs;

    // Queued requests waiting to be claimed.
    struct Pending {
        address who;
        uint256 batchId;
    }

    Pending[] internal pending;

    // Ghost state
    mapping(uint256 => uint256) public claimed0;
    mapping(uint256 => uint256) public claimed1;
    bool public breakerChangedBond;
    bool public settledTwiceInOneEpoch;
    bool public capBroken;
    uint256 public calls;
    uint256 public settlesOk;
    uint256 public swapsOk;
    uint256 public claimsOk;

    constructor(
        SuretyHookHarness _hook,
        IUniswapV4Router04 _router,
        MockERC20 _t0,
        MockERC20 _t1,
        PoolKey memory _key,
        address[2] memory _depositors,
        address[2] memory _curators
    ) {
        hook = _hook;
        shares = _hook.shares();
        router = _router;
        token0 = _t0;
        token1 = _t1;
        key = _key;
        depositors = _depositors;
        curatorAddrs = _curators;
        _t0.approve(address(_router), type(uint256).max);
        _t1.approve(address(_router), type(uint256).max);
    }

    // ---------------------------------------------------------------- actions

    function deposit(uint256 who, uint256 a0, uint256 a1) external {
        calls++;
        address d = depositors[who % 2];
        a0 = bound(a0, 0, 5 ether);
        a1 = bound(a1, 0, 5 ether);
        if (a0 + a1 == 0) return;
        uint256 id = hook.openBatch();
        vm.prank(d);
        hook.deposit(a0, a1);
        pending.push(Pending(d, id));
    }

    function requestWithdraw(uint256 who, uint256 pct) external {
        calls++;
        address d = depositors[who % 2];
        uint256 amount = shares.balanceOf(d) * bound(pct, 1, 50) / 100;
        if (amount == 0) return;
        uint256 id = hook.openBatch();
        vm.prank(d);
        hook.requestWithdraw(amount);
        pending.push(Pending(d, id));
    }

    function claimAll() external {
        calls++;
        uint256 i;
        while (i < pending.length) {
            Pending memory p = pending[i];
            if (!hook.batchAt(p.batchId).processed) {
                i++;
                continue;
            }
            vm.prank(p.who);
            (, uint256 o0, uint256 o1) = hook.claim(p.batchId);
            claimed0[p.batchId] += o0;
            claimed1[p.batchId] += o1;
            claimsOk++;
            pending[i] = pending[pending.length - 1];
            pending.pop();
        }
    }

    function swap(bool zeroForOne, uint256 amount) external {
        calls++;
        amount = bound(amount, 1e9, 3 ether);
        uint64 epochBefore = hook.epochId();
        uint256[2] memory bonds = _bonds();
        try router.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: vm.getBlockTimestamp() + 1
        }) {
            swapsOk++;
            // With no epoch boundary in this swap, only the breaker can have run, and it must never touch a bond.
            if (hook.epochId() == epochBefore) {
                uint256[2] memory afterBonds = _bonds();
                if (afterBonds[0] != bonds[0] || afterBonds[1] != bonds[1]) breakerChangedBond = true;
            }
        } catch {}
    }

    function warp(uint256 secs) external {
        calls++;
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 15 minutes));
    }

    function settle() external {
        calls++;
        try hook.settle() {
            settlesOk++;
            // Right after a successful settle the epoch has just started: a second settle must have nothing to do.
            try hook.settle() {
                settledTwiceInOneEpoch = true;
            } catch {}
            // Every slice was capped at k × bond at the mark when capital was allocated. Deploying at spot can shift
            // the marked value slightly, hence the 5% allowance.
            uint160 mark = hook.markSqrtPrice();
            for (uint8 i; i < 2; i++) {
                SuretyHook.Curator memory c = hook.curatorAt(i);
                if (c.active && hook.sliceValue(i, mark) > c.bond * 10 * 105 / 100 + 1e6) capBroken = true;
            }
        } catch {}
    }

    function setRange(uint256 who, int256 centreSteps, uint256 halfSteps) external {
        calls++;
        int24 ref = hook.twapTick(5 minutes);
        int24 centre = (ref / 60) * 60 + int24(bound(centreSteps, -10, 10)) * 60;
        int24 half = int24(int256(bound(halfSteps, 5, 60))) * 60;
        vm.prank(curatorAddrs[who % 2]);
        try hook.setRange(centre - half, centre + half) {} catch {}
    }

    // ---------------------------------------------------------------- views

    function _bonds() internal view returns (uint256[2] memory b) {
        b[0] = hook.curatorAt(0).bond;
        b[1] = hook.curatorAt(1).bond;
    }
}
