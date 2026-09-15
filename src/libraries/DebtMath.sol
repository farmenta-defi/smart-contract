// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Linked arithmetic for FarmentaMarket's indexed debt ledger.
/// @dev External functions deliberately keep this bytecode out of the market implementation.
library DebtMath {
    uint256 internal constant WAD = 1e18;

    function accrue(
        uint256 borrowIndex,
        uint256 totalBorrowShares,
        uint256 totalBorrows,
        uint256 ratePerSecond,
        uint256 elapsed
    ) internal pure returns (uint256 newIndex, uint256 newTotalBorrows, uint256 interest) {
        newIndex = borrowIndex + borrowIndex * ratePerSecond * elapsed / WAD;
        newTotalBorrows = Math.mulDiv(totalBorrowShares, newIndex, WAD);
        interest = newTotalBorrows - totalBorrows;
    }

    function debtOf(
        uint256 debtShares,
        uint256 borrowIndex
    ) internal pure returns (uint256) {
        return Math.mulDiv(debtShares, borrowIndex, WAD);
    }

    function sharesForBorrow(
        uint256 amount,
        uint256 borrowIndex
    ) internal pure returns (uint256) {
        return Math.mulDiv(amount, WAD, borrowIndex, Math.Rounding.Ceil);
    }

    function sharesForRepay(
        uint256 amount,
        uint256 borrowIndex
    ) internal pure returns (uint256) {
        return Math.mulDiv(amount, WAD, borrowIndex);
    }

    function healthFactor(
        uint256 collateralUsd,
        uint256 ltBps,
        uint256 debtUsdValue
    ) internal pure returns (uint256) {
        return debtUsdValue == 0 ? type(uint256).max : collateralUsd * ltBps * WAD / (debtUsdValue * 10_000);
    }

    /// @notice §6.2's `collateralValue`: principal plus fees capped at 10% of principal, after the
    ///         §6.3 removal haircut, in USD 1e18.
    /// @dev Stated once for everything that reads it: the borrow gate, liquidation's health factor,
    ///      and `MarketLens`. A copy per caller is how a lens drifts from what the market enforces.
    function collateralValue(
        uint256 principalUsd,
        uint256 feesUsd,
        uint256 removeHaircutBps
    ) internal pure returns (uint256) {
        return (principalUsd + Math.min(feesUsd, principalUsd / 10)) * (10_000 - removeHaircutBps) / 10_000;
    }

    function debtUsd(
        uint256 debt,
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        return Math.mulDiv(debt, price, 10 ** decimals);
    }

    function usdToDebt(
        uint256 usdValue,
        uint256 price,
        uint8 decimals
    ) internal pure returns (uint256) {
        return Math.mulDiv(usdValue, 10 ** decimals, price);
    }
}
