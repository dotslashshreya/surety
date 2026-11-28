// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Faucet} from "../src/demo/Faucet.sol";
import {MockToken} from "../src/demo/MockToken.sol";

contract FaucetTest is Test {
    Faucet faucet;
    address owner = makeAddr("owner");
    address judge = makeAddr("judge");

    function setUp() public {
        vm.warp(1_700_000_000);
        faucet = new Faucet(owner);
    }

    function test_claim_gives1mEthAnd3000mUsdc() public {
        vm.prank(judge);
        faucet.claim();
        assertEq(faucet.meth().balanceOf(judge), 1 ether);
        assertEq(faucet.musdc().balanceOf(judge), 3_000 ether);
        assertEq(faucet.meth().symbol(), "mETH");
        assertEq(faucet.musdc().symbol(), "mUSDC");
        assertEq(faucet.meth().decimals(), 18);
    }

    function test_claim_onceEvery24Hours() public {
        vm.prank(judge);
        faucet.claim();
        uint256 next = vm.getBlockTimestamp() + 1 days;
        vm.warp(next - 1);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(Faucet.TooSoon.selector, next));
        faucet.claim();
        vm.warp(next);
        vm.prank(judge);
        faucet.claim();
        assertEq(faucet.meth().balanceOf(judge), 2 ether);
    }

    function test_cooldownIsPerAddress() public {
        vm.prank(judge);
        faucet.claim();
        address other = makeAddr("other");
        vm.prank(other);
        faucet.claim();
        assertEq(faucet.musdc().balanceOf(other), 3_000 ether);
    }

    function test_onlyOwnerCanMintFreely() public {
        vm.prank(judge);
        vm.expectRevert(Faucet.OnlyOwner.selector);
        faucet.ownerMint(judge, 1_000 ether, 0);
        vm.prank(owner);
        faucet.ownerMint(judge, 1_000 ether, 3_000_000 ether);
        assertEq(faucet.meth().balanceOf(judge), 1_000 ether);
    }

    /// The cap can't be bypassed by calling the token directly, e.g. from a block explorer.
    function test_tokensMintableOnlyByFaucet() public {
        MockToken meth = faucet.meth();
        vm.prank(judge);
        vm.expectRevert(MockToken.OnlyMinter.selector);
        meth.mint(judge, 1 ether);
        vm.prank(owner);
        vm.expectRevert(MockToken.OnlyMinter.selector);
        meth.mint(owner, 1 ether);
    }
}
