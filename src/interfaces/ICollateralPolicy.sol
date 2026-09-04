// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ICollateralPolicy
/// @notice Decides which Uniswap positions may back a loan, and on what terms
///         (ARCHITECTURE §4.5, §6).
/// @dev Since v0.5 nothing is accepted automatically: every pool is listed by the owner
///      after an off-chain review (§6.3). The hook-bit check is a precondition of that
///      review, not a gate of its own.
interface ICollateralPolicy {
    /// @notice Risk class of a token, and of a pool through its riskiest token.
    /// @dev `NONE` is zero on purpose. An unconfigured token must not read as blue-chip,
    ///      which is what would happen if the safest tier occupied the default slot.
    enum Tier {
        NONE,
        BLUE_CHIP,
        MEME
    }

    /// @notice The terms a listed pool lends on.
    /// @param maxLtvBps Highest LTV a borrow may reach, in basis points.
    /// @param ltBps Liquidation threshold **as of now** — already resolved through any ramp.
    /// @param liquidatorBonusBps Net bonus a liquidator receives.
    /// @param removeHaircutBps Value skimmed by the pool's hook when liquidity is removed,
    ///        recorded during review (§6.3). Zero for hooks that take nothing.
    /// @param debtCapUsdg Ceiling on this pool's debt, in USDG (6 decimals) — the same unit
    ///        as the market's `poolDebt` ledger, so the cap is comparable without a price.
    /// @param minPositionUsd Smallest position accepted as collateral, USD scaled 1e18.
    /// @param tier Which market may take it.
    struct Terms {
        uint16 maxLtvBps;
        uint16 ltBps;
        uint16 liquidatorBonusBps;
        uint16 removeHaircutBps;
        uint128 debtCapUsdg;
        uint128 minPositionUsd;
        Tier tier;
    }

    /// @notice Terms for a listed pool, with the liquidation threshold already resolved
    ///         through any active ramp.
    /// @dev Reverts if the pool is not listed. There is no "unlisted returns zeros" path:
    ///      zeroed terms would read as a pool that lends nothing rather than one that must
    ///      not be touched, and those are different mistakes to make.
    function termsOf(
        PoolId poolId
    ) external view returns (Terms memory);

    /// @notice Whether new collateral and new borrowing are currently allowed for a pool.
    /// @dev False once frozen. Existing loans keep working regardless — repay, collect,
    ///      decrease, withdraw and liquidate all stay open, because trapping collateral or
    ///      switching off liquidation would manufacture bad debt (§6.5).
    function acceptsNewPositions(
        PoolId poolId
    ) external view returns (bool);
}
