// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockToken
/// @notice A test token (18 decimals) for the demo pool. Only its faucet can mint, so the faucet's daily cap
///         can't be bypassed by calling the token directly from a block explorer.
contract MockToken is ERC20 {
    address public immutable minter;

    error OnlyMinter();

    constructor(string memory name_, string memory symbol_, address minter_) ERC20(name_, symbol_) {
        minter = minter_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }
}
