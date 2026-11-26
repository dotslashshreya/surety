// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {SuretyBase} from "./utils/SuretyBase.sol";
import {SuretyHook} from "../src/SuretyHook.sol";

/// @notice The frontend is built from these events, so each is checked for its indexed fields, and for its data
///         wherever the value is known exactly.
contract SuretyEventsTest is SuretyBase {
    function test_events_curatorRegistered_rangeSet() public {
        vm.startPrank(careful);
        vm.expectEmit(true, false, false, true, address(hook));
        emit SuretyHook.CuratorRegistered(careful, 20 ether);
        hook.registerCurator(20 ether);
        vm.expectEmit(true, false, false, true, address(hook));
        emit SuretyHook.RangeSet(careful, -6000, 6000);
        hook.setRange(-6000, 6000);
        vm.stopPrank();
    }

    function test_events_deposited_withdrawRequested() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit SuretyHook.Deposited(alice, 1, 100 ether, 50 ether);
        _deposit(alice, 100 ether, 50 ether);
        _register(careful, 20 ether, -6000, 6000);
        _roll();
        vm.prank(alice);
        hook.claim(1);

        uint256 id = hook.openBatch();
        vm.expectEmit(true, true, false, true, address(hook));
        emit SuretyHook.WithdrawRequested(alice, id, 10 ether);
        vm.prank(alice);
        hook.requestWithdraw(10 ether);
    }

    /// settle() at the first boundary: the epoch is scored and closed, then the queued batch is processed.
    function test_events_epochSettled_batchProcessed() public {
        _deposit(alice, 100 ether, 100 ether);
        _register(careful, 20 ether, -6000, 6000);
        _warpToEpochEnd();
        vm.expectEmit(true, false, false, false, address(hook));
        emit SuretyHook.EpochSettled(1, 0, 0);
        vm.expectEmit(true, false, false, true, address(hook));
        emit SuretyHook.BatchProcessed(1, 200 ether, 0, 0, 0); // first deposit: 200 at price 1, nothing burned
        vm.prank(keeper);
        hook.settle();
    }

    /// The trend: both curators are scored and slashed inside the swap, then settle() reallocates and pays the reward.
    function test_events_scored_slashed_reallocated_rewardPaid() public {
        _bootstrap();
        _swap(true, 60 ether);
        vm.warp(hook.epochEnd());

        vm.expectEmit(true, true, false, false, address(hook));
        emit SuretyHook.CuratorScored(2, careful, 0, 0, 0);
        vm.expectEmit(true, true, false, false, address(hook));
        emit SuretyHook.CuratorSlashed(2, careful, 0);
        vm.expectEmit(true, true, false, false, address(hook));
        emit SuretyHook.CuratorScored(2, reckless, 0, 0, 0);
        vm.expectEmit(true, true, false, false, address(hook));
        emit SuretyHook.CuratorSlashed(2, reckless, 0);
        vm.expectEmit(true, false, false, false, address(hook));
        emit SuretyHook.EpochSettled(2, 0, 0);
        _swap(true, 0.001 ether); // enforcement runs inside this swap

        _hold(6 minutes);
        uint256 reward = hook.rewardPool();
        vm.expectEmit(true, true, true, false, address(hook));
        emit SuretyHook.Reallocated(2, reckless, careful, 0);
        vm.expectEmit(true, false, false, true, address(hook));
        emit SuretyHook.SettleRewardPaid(keeper, reward);
        vm.prank(keeper);
        hook.settle();
    }

    function test_events_performanceFeePaid() public {
        _bootstrap();
        for (uint256 i; i < 20; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _swap(i % 2 == 0, 3 ether);
        }
        _warpToEpochEnd();
        vm.expectEmit(true, true, false, false, address(hook));
        emit SuretyHook.PerformanceFeePaid(2, careful, 0, 0);
        vm.expectEmit(true, true, false, false, address(hook));
        emit SuretyHook.PerformanceFeePaid(2, reckless, 0, 0);
        vm.prank(keeper);
        hook.settle();
    }

    function test_events_curatorExited() public {
        _bootstrap();
        uint64 id = hook.epochId();
        vm.expectEmit(true, false, false, true, address(hook));
        emit SuretyHook.CuratorExited(reckless, id + 2); // the epoch the bond unlocks
        vm.prank(reckless);
        hook.exitCurator();
    }

    /// The freeze happens inside one of many swaps, so the logs are searched for it.
    function test_events_curatorFrozen() public {
        _bootstrap();
        uint64 id = hook.epochId();
        vm.warp(vm.getBlockTimestamp() + 60);
        _swap(true, 80 ether);
        vm.recordLogs();
        _hold(6 minutes);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == SuretyHook.CuratorFrozen.selector
                    && uint256(logs[i].topics[1]) == id && address(uint160(uint256(logs[i].topics[2]))) == reckless
            ) found = true;
        }
        assertTrue(found, "CuratorFrozen(epoch, reckless) emitted");
    }
}
