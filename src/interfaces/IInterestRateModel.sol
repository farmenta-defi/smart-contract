// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICollateralPolicy} from "./ICollateralPolicy.sol";

/// @title IInterestRateModel
/// @notice Supplies the borrow rate for a market utilisation, scaled by 1e18.
interface IInterestRateModel {
    function ratePerSecond(
        ICollateralPolicy.Tier tier,
        uint256 utilization
    ) external pure returns (uint256);
}
