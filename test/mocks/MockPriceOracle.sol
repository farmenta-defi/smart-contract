// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Oracle stub with settable prices, for testing valuation independently of feeds.
/// @dev Lets a test move the oracle while the forked pool stays exactly where it is — which
///      is the only way to show that valuation follows the oracle and not the pool.
contract MockPriceOracle is IPriceOracle {
    error PriceNotSet(Currency currency);

    mapping(Currency currency => uint256) internal _price;
    mapping(Currency currency => uint8) internal _decimals;

    function set(
        Currency currency,
        uint256 usd1e18,
        uint8 tokenDecimals
    ) external {
        _price[currency] = usd1e18;
        _decimals[currency] = tokenDecimals;
    }

    /// @dev Reverts on an unset currency rather than returning zero, matching the real
    ///      oracle's contract: there is no sentinel for "unavailable".
    function price(
        Currency currency
    ) external view returns (uint256) {
        uint256 p = _price[currency];
        if (p == 0) revert PriceNotSet(currency);
        return p;
    }

    function decimals(
        Currency currency
    ) external view returns (uint8) {
        return _decimals[currency];
    }
}
