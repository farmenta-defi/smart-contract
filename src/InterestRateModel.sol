// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/// @title InterestRateModel
/// @notice Immutable kinked borrow-rate curves for both market tiers.
contract InterestRateModel is IInterestRateModel {
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    error TierNotSet();
    error UtilizationTooHigh(uint256 utilization);

    function ratePerSecond(
        ICollateralPolicy.Tier tier,
        uint256 utilization
    ) external pure returns (uint256) {
        if (utilization > WAD) revert UtilizationTooHigh(utilization);

        (uint256 kink, uint256 slope1PerYear, uint256 slope2PerYear) = _parameters(tier);
        uint256 annualRate = utilization <= kink
            ? slope1PerYear * utilization / kink
            : slope1PerYear + slope2PerYear * (utilization - kink) / (WAD - kink);
        return annualRate / SECONDS_PER_YEAR;
    }

    function _parameters(
        ICollateralPolicy.Tier tier
    ) private pure returns (uint256 kink, uint256 slope1PerYear, uint256 slope2PerYear) {
        if (tier == ICollateralPolicy.Tier.BLUE_CHIP) return (80e16, 4e16, 60e16);
        if (tier == ICollateralPolicy.Tier.MEME) return (70e16, 8e16, 100e16);
        revert TierNotSet();
    }
}
