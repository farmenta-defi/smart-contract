// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice A replacement implementation with the timelock taken out, for the FAR-21 tests.
/// @dev What an owner would have to install to change `TIMELOCK_DELAY`: the delay lives in the
///      implementation's code, so only another implementation can carry a different one.
contract UnlockedMarketMock is UUPSUpgradeable {
    uint256 public constant TIMELOCK_DELAY = 0;

    function _authorizeUpgrade(
        address
    ) internal override {}
}
