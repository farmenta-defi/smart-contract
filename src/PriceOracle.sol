// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CollateralPolicy} from "./CollateralPolicy.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @title PriceOracle
/// @notice Reads policy-configured Chainlink feeds as USD prices (ARCHITECTURE §4.3, §5.2).
/// @dev Token decimals and the feed address are both listing-time metadata. In particular,
///      token decimals must never be read live because a mutable token implementation could
///      otherwise alter every position's valuation after it has been accepted as collateral.
contract PriceOracle is IPriceOracle {
    uint256 public constant MAX_PRICE_AGE = 25 hours;
    uint8 internal constant USD_DECIMALS = 18;

    CollateralPolicy public immutable policy;

    error TokenNotConfigured(Currency currency);
    error PriceFeedNotConfigured(Currency currency);
    error InvalidPrice(Currency currency, int256 answer);
    error StalePrice(Currency currency, uint256 updatedAt);

    constructor(
        CollateralPolicy policy_
    ) {
        policy = policy_;
    }

    /// @inheritdoc IPriceOracle
    function price(
        Currency currency
    ) public view returns (uint256 usd1e18) {
        (, address priceFeed) = _config(currency);
        if (priceFeed == address(0)) revert PriceFeedNotConfigured(currency);

        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(priceFeed).latestRoundData();
        if (answer <= 0) revert InvalidPrice(currency, answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_PRICE_AGE) {
            revert StalePrice(currency, updatedAt);
        }

        // Safe after `answer > 0`; a signed Chainlink answer must not be cast before this.
        uint256 unsignedAnswer = uint256(answer);
        uint8 feedDecimals = IAggregatorV3(priceFeed).decimals();
        return _scaleToUsd1e18(unsignedAnswer, feedDecimals);
    }

    /// @inheritdoc IPriceOracle
    function priceForLiquidation(
        Currency currency
    ) external view returns (uint256 usd1e18) {
        return price(currency);
    }

    /// @inheritdoc IPriceOracle
    function decimals(
        Currency currency
    ) external view returns (uint8) {
        (uint8 tokenDecimals,) = _config(currency);
        return tokenDecimals;
    }

    function _config(
        Currency currency
    ) internal view returns (uint8 tokenDecimals, address priceFeed) {
        bool enabled;
        (enabled,, tokenDecimals, priceFeed) = policy.tokenConfig(currency);
        if (!enabled) revert TokenNotConfigured(currency);
    }

    function _scaleToUsd1e18(
        uint256 answer,
        uint8 feedDecimals
    ) internal pure returns (uint256) {
        if (feedDecimals == USD_DECIMALS) return answer;
        if (feedDecimals < USD_DECIMALS) return answer * 10 ** (USD_DECIMALS - feedDecimals);
        return answer / 10 ** (feedDecimals - USD_DECIMALS);
    }
}
