// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title PositionAmounts
/// @notice Converts a concentrated-liquidity position into the token amounts it holds at a
///         given price, and prices uncollected fees out of fee-growth deltas.
/// @dev Uniswap ships `getAmountsForLiquidity` only in `v4-core/test/utils/`, which is
///      marked `UNLICENSED`; the MIT copy in v4-periphery covers the opposite direction
///      (amounts → liquidity) only. So this is built on `SqrtPriceMath` (MIT) instead,
///      which is the fallback ARCHITECTURE.md §5.1 anticipated.
///
///      Rounding is **down** everywhere: a position must never be valued above what it can
///      actually return, since that value backs a loan.
library PositionAmounts {
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Token amounts a position holds at `sqrtPriceX96`.
    /// @dev The caller decides which price to pass. Farmenta passes an **oracle-derived**
    ///      price rather than the pool's spot price, so manipulating spot cannot change the
    ///      amounts a position is valued at (§5.1, the Revert v4lend pattern).
    /// @param sqrtPriceX96 Price to value at, as sqrt(token1/token0) in Q64.96.
    /// @param sqrtPriceLowerX96 sqrt price at `tickLower`.
    /// @param sqrtPriceUpperX96 sqrt price at `tickUpper`.
    /// @param liquidity Position liquidity.
    /// @return amount0 Amount of currency0 held.
    /// @return amount1 Amount of currency1 held.
    function forLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceLowerX96 > sqrtPriceUpperX96) {
            (sqrtPriceLowerX96, sqrtPriceUpperX96) = (sqrtPriceUpperX96, sqrtPriceLowerX96);
        }

        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            // Below the range: entirely currency0.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
            // In range: a mix, split at the current price.
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            // At or above the range: entirely currency1.
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        }
    }

    /// @notice Uncollected fees, from the growth accrued since the position last synced.
    /// @dev v4 has no `tokensOwed`: fees exist only as the difference between the pool's
    ///      current fee growth inside the range and the value cached on the position. The
    ///      subtraction is expected to wrap — growth counters are unbounded and wrap by
    ///      design — which is why it is `unchecked`, matching Uniswap's own guidance.
    function feesOwed(
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 liquidity
    ) internal pure returns (uint256 fees0, uint256 fees1) {
        unchecked {
            fees0 = FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, Q128);
            fees1 = FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, Q128);
        }
    }
}
