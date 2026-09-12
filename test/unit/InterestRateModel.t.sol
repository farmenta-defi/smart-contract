// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";

contract InterestRateModelTest is Test {
    uint256 internal constant YEAR = 365 days;

    function test_blueChipBelowKinkScalesSlopeOne() public {
        InterestRateModel model = new InterestRateModel();
        assertApproxEqAbs(
            model.ratePerSecond(ICollateralPolicy.Tier.BLUE_CHIP, 30e16) * YEAR,
            15e15,
            1e8,
            "30% utilization should be 1.5% annualized"
        );
    }

    function test_blueChipAboveKinkAddsSlopeTwo() public {
        InterestRateModel model = new InterestRateModel();
        assertApproxEqAbs(
            model.ratePerSecond(ICollateralPolicy.Tier.BLUE_CHIP, 90e16) * YEAR,
            34e16,
            1e8,
            "90% utilization should be 34% annualized"
        );
    }

    function test_memeKinkMatchesEightPercentSlopeOne() public {
        InterestRateModel model = new InterestRateModel();
        assertApproxEqAbs(
            model.ratePerSecond(ICollateralPolicy.Tier.MEME, 70e16) * YEAR,
            8e16,
            1e8,
            "meme kink should be 8% annualized"
        );
    }
}
