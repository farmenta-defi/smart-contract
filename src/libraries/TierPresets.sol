// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";

/// @title TierPresets
/// @notice Per-tier risk parameters from ARCHITECTURE §6.2 — defaults **and** outer bounds.
/// @dev Since v0.5 these are not the values in force. Each listing carries its own numbers
///      and may deviate only toward stricter; the policy rejects anything looser. That makes
///      the loosest terms Farmenta can ever offer a property readable from this file, rather
///      than a promise resting on whoever fills in the listing form.
///
///      "Stricter" has a direction per parameter, and they do not all point the same way:
///      LTV and liquidation threshold may only go **down**, the liquidator bonus only **up**
///      (a larger bonus gets bad debt cleared faster), caps only down, minimum position size
///      only up.
library TierPresets {
    /// @param maxLtvBps Ceiling on a listing's max LTV.
    /// @param ltBps Ceiling on a listing's liquidation threshold.
    /// @param minLiquidatorBonusBps Floor on a listing's liquidator bonus.
    /// @param maxDebtCapUsdg Ceiling on a listing's debt cap, in **USDG** (6 decimals), not
    ///        USD 1e18. §6.2 and §6.5 store the cap as an absolute USDG amount, and §4.1's
    ///        `poolDebt` ledger is denominated the same way — so capping debt never needs a
    ///        price. §6.2 states the pool rule as a share of pool TVL, which is not
    ///        computable on-chain; the market cap is the enforceable bound, and the
    ///        percentage rule stays an off-chain input to the number the owner writes.
    /// @param minPositionUsd Floor on a listing's minimum position value, USD 1e18.
    struct Preset {
        uint16 maxLtvBps;
        uint16 ltBps;
        uint16 minLiquidatorBonusBps;
        uint128 maxDebtCapUsdg;
        uint128 minPositionUsd;
    }

    uint16 internal constant BPS = 10_000;

    /// @notice Blue-chip: ETH/USDG and WETH/USDG.
    function blueChip() internal pure returns (Preset memory) {
        return Preset({
            maxLtvBps: 6500, ltBps: 7500, minLiquidatorBonusBps: 500, maxDebtCapUsdg: 500_000e6, minPositionUsd: 50e18
        });
    }

    /// @notice Meme: xyz/USDG on allowlisted pools.
    function meme() internal pure returns (Preset memory) {
        return Preset({
            maxLtvBps: 3000, ltBps: 4000, minLiquidatorBonusBps: 1000, maxDebtCapUsdg: 50_000e6, minPositionUsd: 50e18
        });
    }

    /// @notice Preset for a tier.
    /// @dev Reverts on `Tier.NONE` rather than returning a zeroed preset: a zero preset would
    ///      accept every listing as "stricter than nothing".
    function forTier(
        ICollateralPolicy.Tier tier
    ) internal pure returns (Preset memory) {
        if (tier == ICollateralPolicy.Tier.BLUE_CHIP) return blueChip();
        if (tier == ICollateralPolicy.Tier.MEME) return meme();
        revert NoPresetForTier();
    }

    error NoPresetForTier();
}
