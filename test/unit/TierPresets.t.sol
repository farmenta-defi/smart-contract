// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";

/// @notice Checks the preset numbers against ARCHITECTURE §6.2, and the relationships
///         between them that must hold whatever the numbers become.
contract TierPresetsTest is Test {
    /// @dev Transcribed from §6.2. If the spec changes these, this test is where the two are
    ///      meant to collide rather than drift apart quietly.
    function test_blueChipMatchesTheSpec() public pure {
        TierPresets.Preset memory p = TierPresets.blueChip();
        assertEq(p.maxLtvBps, 6500, "max LTV");
        assertEq(p.ltBps, 7500, "liquidation threshold");
        assertEq(p.minLiquidatorBonusBps, 500, "liquidator bonus");
        assertEq(p.maxDebtCapUsdg, 500_000e6, "market debt cap");
        assertEq(p.minPositionUsd, 50e18, "minimum position");
    }

    function test_memeMatchesTheSpec() public pure {
        TierPresets.Preset memory p = TierPresets.meme();
        assertEq(p.maxLtvBps, 3000, "max LTV");
        assertEq(p.ltBps, 4000, "liquidation threshold");
        assertEq(p.minLiquidatorBonusBps, 1000, "liquidator bonus");
        assertEq(p.maxDebtCapUsdg, 50_000e6, "market debt cap");
        assertEq(p.minPositionUsd, 50e18, "minimum position");
    }

    /// @dev Max LTV must sit below the liquidation threshold, or a loan would be liquidatable
    ///      the moment it opened. §17 states this as LT > Max LTV.
    function test_borrowingRoomExistsInEveryTier() public pure {
        assertLt(TierPresets.blueChip().maxLtvBps, TierPresets.blueChip().ltBps, "blue-chip");
        assertLt(TierPresets.meme().maxLtvBps, TierPresets.meme().ltBps, "meme");
    }

    /// @dev The riskier tier must be stricter on every axis. This is the property the tier
    ///      split exists for; two tiers with crossed parameters would be worse than one.
    function test_memeIsStricterThanBlueChipEverywhere() public pure {
        TierPresets.Preset memory bc = TierPresets.blueChip();
        TierPresets.Preset memory mm = TierPresets.meme();

        assertLt(mm.maxLtvBps, bc.maxLtvBps, "meme must lend less against the same value");
        assertLt(mm.ltBps, bc.ltBps, "meme must liquidate earlier");
        assertGt(mm.minLiquidatorBonusBps, bc.minLiquidatorBonusBps, "meme must pay liquidators more");
        assertLt(mm.maxDebtCapUsdg, bc.maxDebtCapUsdg, "meme must risk less in total");
    }

    function test_thresholdsStayWithinOneHundredPercent() public pure {
        assertLe(TierPresets.blueChip().ltBps, TierPresets.BPS, "blue-chip LT above 100%");
        assertLe(TierPresets.meme().ltBps, TierPresets.BPS, "meme LT above 100%");
    }

    function test_lookupByTier() public pure {
        assertEq(TierPresets.forTier(ICollateralPolicy.Tier.BLUE_CHIP).maxLtvBps, TierPresets.blueChip().maxLtvBps);
        assertEq(TierPresets.forTier(ICollateralPolicy.Tier.MEME).maxLtvBps, TierPresets.meme().maxLtvBps);
    }

    /// @dev A zeroed preset would treat every listing as stricter than the default and wave
    ///      it through, so the unconfigured tier must revert rather than return one.
    function test_unsetTierHasNoPreset() public {
        vm.expectRevert(TierPresets.NoPresetForTier.selector);
        this.presetFor(ICollateralPolicy.Tier.NONE);
    }

    function presetFor(
        ICollateralPolicy.Tier tier
    ) external pure returns (TierPresets.Preset memory) {
        return TierPresets.forTier(tier);
    }
}
