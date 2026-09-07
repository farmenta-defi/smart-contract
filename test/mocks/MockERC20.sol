// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mintable ERC-20 with settable decimals.
/// @dev Exists so unit tests can hand the vault a 6-decimal asset without a fork. USDG has 6
///      decimals while the share token derives its own from that plus the offset, so a mock
///      fixed at 18 would hide every decimals mistake this repo cares about.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}
