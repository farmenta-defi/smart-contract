// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";

/// @title InterestRateModel
/// @notice Immutable kinked borrow-rate curve from ARCHITECTURE §7.
contract InterestRateModel is IInterestRateModel {
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    uint256 public immutable kink;
    uint256 public immutable slope1PerYear;
    uint256 public immutable slope2PerYear;

    error TierNotSet();
    error UtilizationTooHigh(uint256 utilization);

    constructor(ICollateralPolicy.Tier tier) {
        if (tier == ICollateralPolicy.Tier.BLUE_CHIP) {
            kink = 80e16;
            slope1PerYear = 4e16;
            slope2PerYear = 60e16;
        } else if (tier == ICollateralPolicy.Tier.MEME) {
            kink = 70e16;
            slope1PerYear = 8e16;
            slope2PerYear = 100e16;
        } else {
            revert TierNotSet();
        }
    }

    function ratePerSecond(uint256 utilization) external view returns (uint256) {
        if (utilization > WAD) revert UtilizationTooHigh(utilization);

        uint256 annualRate = utilization <= kink
            ? slope1PerYear * utilization / kink
            : slope1PerYear + slope2PerYear * (utilization - kink) / (WAD - kink);
        return annualRate / SECONDS_PER_YEAR;
    }
}
