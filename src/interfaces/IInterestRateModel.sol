// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IInterestRateModel
/// @notice Supplies the borrow rate for a market utilisation, scaled by 1e18.
interface IInterestRateModel {
    function ratePerSecond(
        uint256 utilization
    ) external view returns (uint256);
}
