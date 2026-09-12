// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {RobinhoodChain} from "./constants/RobinhoodChain.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IPyth} from "./interfaces/IPyth.sol";

/// @title PriceOracle
/// @notice Reads policy-configured Chainlink feeds as USD prices (ARCHITECTURE §4.3, §5.2).
/// @dev Token decimals and the feed address are both listing-time metadata. In particular,
///      token decimals must never be read live because a mutable token implementation could
///      otherwise alter every position's valuation after it has been accepted as collateral.
contract PriceOracle is IPriceOracle {
    uint256 public constant MAX_PRICE_AGE = 25 hours;
    uint8 internal constant USD_DECIMALS = 18;
    uint256 internal constant BPS = 10_000;

    ICollateralPolicy public immutable policy;
    IPyth public immutable pyth;

    error PriceFeedNotConfigured(Currency currency);
    error InvalidPrice(Currency currency, int256 answer);
    error StalePrice(Currency currency, uint256 updatedAt);
    error PythNotConfigured();
    error InvalidPythPrice(int64 price, int32 expo, uint256 publishTime);

    constructor(
        ICollateralPolicy policy_,
        IPyth pyth_
    ) {
        policy = policy_;
        if (address(pyth_) == address(0)) revert PythNotConfigured();
        pyth = pyth_;
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
    function pythEthUsd() external view returns (uint256 usd1e18, uint256 publishTime) {
        try pyth.getPriceUnsafe(RobinhoodChain.PYTH_ETH_USD_PRICE_ID) returns (IPyth.Price memory observation) {
            if (observation.publishTime > block.timestamp || observation.price <= 0) return (0, 0);
            (bool valid, uint256 normalized) = _tryPythUsd1e18(observation);
            if (!valid) return (0, 0);
            return (normalized, observation.publishTime);
        } catch {
            return (0, 0);
        }
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
        (,, tokenDecimals, priceFeed) = policy.tokenConfig(currency);
        if (priceFeed == address(0)) revert PriceFeedNotConfigured(currency);
    }

    function _scaleToUsd1e18(
        uint256 answer,
        uint8 feedDecimals
    ) internal pure returns (uint256) {
        if (feedDecimals == USD_DECIMALS) return answer;
        if (feedDecimals < USD_DECIMALS) return answer * 10 ** (USD_DECIMALS - feedDecimals);
        return answer / 10 ** (feedDecimals - USD_DECIMALS);
    }

    /// @dev Pyth's signed exponent is normalized here, after the value has passed its signed
    ///      positivity check. ETH/USD normally uses `expo = -8`; the bounds merely keep a
    ///      malformed response from turning an exponentiation into an overflow or zero price.
    function _tryPythUsd1e18(
        IPyth.Price memory pythPrice
    ) private pure returns (bool valid, uint256 usd1e18) {
        if (pythPrice.price <= 0) return (false, 0);

        int256 scale = int256(uint256(USD_DECIMALS)) + int256(pythPrice.expo);
        if (scale > 58 || scale < -77) return (false, 0);

        uint256 unsignedPrice = uint64(pythPrice.price);
        if (scale >= 0) return (true, unsignedPrice * 10 ** uint256(scale));
        return (true, unsignedPrice / 10 ** uint256(-scale));
    }
}
