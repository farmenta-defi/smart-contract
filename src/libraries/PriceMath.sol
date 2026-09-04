// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title PriceMath
/// @notice Turns oracle USD prices into the sqrt price Uniswap's position math expects, and
///         measures how far a pool's spot price has drifted from it.
/// @dev This is what makes valuation resistant to spot manipulation (ARCHITECTURE §5.1, the
///      Revert v4lend pattern): a position's token amounts are computed at a price derived
///      from oracles, so pushing the pool around does not change what a position is worth.
///      The pool's own price is then only used to *detect* drift, never to value.
library PriceMath {
    /// @notice A price feed returned zero. Never valued against — zero would place the
    ///         derived price outside every tick range and silently value positions as
    ///         entirely one-sided.
    error ZeroPrice();

    /// @notice The derived price falls outside the range Uniswap can represent.
    error PriceOutOfRange();

    uint256 internal constant BPS = 10_000;

    /// @notice sqrt price implied by two USD prices, in Uniswap's Q64.96 form.
    /// @dev Uniswap's sqrt price is defined on **raw** units: sqrt(amount1 / amount0) << 96.
    ///      Feeding it USD prices therefore has to divide out each token's decimals, which is
    ///      where the USDG/ETH asymmetry (6 vs 18) enters every valuation in this protocol.
    ///
    ///      Computed as sqrt(ratio << 128) << 32 rather than sqrt(ratio << 192): the latter
    ///      overflows for prices near the top of Uniswap's representable range, since
    ///      MAX_SQRT_PRICE squared already exceeds 2**256.
    ///
    /// @param price0 USD price of one whole currency0, scaled 1e18.
    /// @param price1 USD price of one whole currency1, scaled 1e18.
    /// @param decimals0 Decimals of currency0.
    /// @param decimals1 Decimals of currency1.
    function derivedSqrtPriceX96(
        uint256 price0,
        uint256 price1,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint160) {
        if (price0 == 0 || price1 == 0) revert ZeroPrice();

        // ratio = (price0 / 10**decimals0) / (price1 / 10**decimals1), i.e. how many raw
        // units of currency1 one raw unit of currency0 is worth. Overflow here is a revert,
        // not a wrap: a price large enough to overflow is not a price we should value against.
        uint256 numerator = price0 * (10 ** uint256(decimals1));
        uint256 denominator = price1 * (10 ** uint256(decimals0));

        uint256 sqrtPriceX96 = Math.sqrt(FullMath.mulDiv(numerator, 1 << 128, denominator)) << 32;

        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }
        // Safe: the bound above is MAX_SQRT_PRICE, which is itself a uint160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(sqrtPriceX96);
    }

    /// @notice How far a pool's spot price sits from the oracle-derived price, in bps.
    /// @dev Compared on **price**, not sqrt price, because that is what the ±2% borrow rule
    ///      in §5.2 is written against — a 2% move in price is only a ~1% move in its root.
    ///      Symmetric: the result does not depend on which side is larger.
    /// @return deviationBps Absolute deviation relative to the derived price.
    function spotDeviationBps(
        uint160 sqrtSpotX96,
        uint160 sqrtDerivedX96
    ) internal pure returns (uint256) {
        if (sqrtDerivedX96 == 0) revert ZeroPrice();

        // Squaring overflows 256 bits near the top of the range; mulDiv carries the 512-bit
        // intermediate, and shifting back by 96 keeps both sides in one Q96 scale.
        uint256 spot = FullMath.mulDiv(sqrtSpotX96, sqrtSpotX96, 1 << 96);
        uint256 derived = FullMath.mulDiv(sqrtDerivedX96, sqrtDerivedX96, 1 << 96);

        uint256 diff = spot > derived ? spot - derived : derived - spot;
        return FullMath.mulDiv(diff, BPS, derived);
    }
}
