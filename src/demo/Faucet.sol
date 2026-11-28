// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockToken} from "./MockToken.sol";

/// @title Faucet
/// @notice Creates the demo's two test tokens and hands them out: 1 mETH and 3,000 mUSDC per address, at most once
///         every 24 hours. Enough to try a deposit, too little to move a deeply seeded pool. The owner can mint
///         more to seed the pool and fund the curators' bonds.
contract Faucet {
    uint256 public constant METH_PER_CLAIM = 1 ether;
    uint256 public constant MUSDC_PER_CLAIM = 3_000 ether;
    uint256 public constant COOLDOWN = 1 days;

    MockToken public immutable meth;
    MockToken public immutable musdc;
    address public immutable owner;

    mapping(address => uint256) public nextClaimAt;

    event Claimed(address indexed to, uint256 meth, uint256 musdc);

    error TooSoon(uint256 nextClaimAt);
    error OnlyOwner();

    constructor(address owner_) {
        owner = owner_;
        meth = new MockToken("Mock Ether", "mETH", address(this));
        musdc = new MockToken("Mock USD Coin", "mUSDC", address(this));
    }

    /// @notice 1 mETH and 3,000 mUSDC to the caller, at most once every 24 hours.
    function claim() external {
        uint256 next = nextClaimAt[msg.sender];
        if (block.timestamp < next) revert TooSoon(next);
        nextClaimAt[msg.sender] = block.timestamp + COOLDOWN;
        meth.mint(msg.sender, METH_PER_CLAIM);
        musdc.mint(msg.sender, MUSDC_PER_CLAIM);
        emit Claimed(msg.sender, METH_PER_CLAIM, MUSDC_PER_CLAIM);
    }

    /// @notice Owner-only: mint any amount, to seed the pool and fund bonds.
    function ownerMint(address to, uint256 methAmount, uint256 musdcAmount) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (methAmount > 0) meth.mint(to, methAmount);
        if (musdcAmount > 0) musdc.mint(to, musdcAmount);
    }
}
