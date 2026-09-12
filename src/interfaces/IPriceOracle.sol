// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ICollateralPolicy} from "./ICollateralPolicy.sol";

/// @title IPriceOracle
/// @notice USD prices for the currencies Farmenta accepts (ARCHITECTURE §4.3, §5.2).
interface IPriceOracle {
    /// @notice USD price of one **whole** token, scaled 1e18.
    /// @dev Must revert rather than return a stale, zero, or out-of-bounds price. Callers
    ///      treat a returned value as usable; there is no sentinel for "unavailable".
    function price(
        Currency currency
    ) external view returns (uint256 usd1e18);

    /// @notice USD price used when deciding whether a position is liquidatable.
    /// @dev Kept distinct from `price` even while MVP returns the same source, so a future
    ///      liquidation-specific source does not require changing every liquidation caller.
    function priceForLiquidation(
        Currency currency
    ) external view returns (uint256 usd1e18);

    /// @notice Reverts when a new borrow would rely on a depegged USDG price or an
    ///         uncorroborated fresh ETH price.
    /// @dev The Pyth comparison applies only to blue-chip borrowing. A stale Pyth update is
    ///      deliberately ignored: Pyth is a pull oracle and no borrower should be able to
    ///      make Chainlink unavailable merely by not pushing a new Pyth update.
    function checkBorrowPrice(
        ICollateralPolicy.Tier tier
    ) external view;

    /// @notice Decimals of `currency`, with native ETH reported as 18.
    /// @dev Read from `decimals()` at listing time and stored, never read live: a token that
    ///      could change its reported decimals could change every position's value. §5.1
    ///      records this alongside the token's price source, so it is served from here rather
    ///      than making every caller reach into the policy for it.
    function decimals(
        Currency currency
    ) external view returns (uint8);
}
