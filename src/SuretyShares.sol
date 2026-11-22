// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SuretyShares
/// @notice Vault shares for a SuretyHook. Only the hook can mint, burn or move shares on a holder's behalf.
/// @dev Kept separate from the hook so the hook's runtime code stays under the 24 KB limit.
contract SuretyShares is ERC20 {
    address public immutable vault;

    error OnlyVault();

    constructor() ERC20("Surety Vault Share", "SURE") {
        vault = msg.sender;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    /// @dev Used by the hook to escrow shares a holder queues for withdrawal, and to hand out claimed shares.
    function move(address from, address to, uint256 amount) external onlyVault {
        _transfer(from, to, amount);
    }
}
