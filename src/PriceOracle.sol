// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TwapRecorder} from "./TwapRecorder.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {TierPresets} from "./libraries/TierPresets.sol";

/// @title PriceOracle
/// @notice Reads policy-configured Chainlink feeds as USD prices (ARCHITECTURE §4.3, §5.2).
/// @dev Token decimals and the feed address are both listing-time metadata. In particular,
///      token decimals must never be read live because a mutable token implementation could
///      otherwise alter every position's valuation after it has been accepted as collateral.
contract PriceOracle is IPriceOracle {
    uint256 public constant MAX_PRICE_AGE = 25 hours;
    uint8 internal constant USD_DECIMALS = 18;

    ICollateralPolicy public immutable policy;
    TwapRecorder public immutable recorder;

    error PriceFeedNotConfigured(Currency currency);
    error InvalidPrice(Currency currency, int256 answer);
    error StalePrice(Currency currency, uint256 updatedAt);
    error TwapRecorderNotConfigured();
    error MemeTwapUnavailable(PoolId poolId);
    error MemeCurrencyNotInPool(Currency currency, PoolId poolId);
    error MemeSpotUnavailable(PoolId poolId);

    constructor(
        ICollateralPolicy policy_,
        TwapRecorder recorder_
    ) {
        policy = policy_;
        if (address(recorder_) == address(0)) revert TwapRecorderNotConfigured();
        recorder = recorder_;
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
    function price(
        Currency currency,
        PoolKey calldata key
    ) external view returns (uint256 usd1e18) {
        return _poolPrice(currency, key, false);
    }

    /// @inheritdoc IPriceOracle
    function priceForLiquidation(
        Currency currency
    ) external view returns (uint256 usd1e18) {
        return price(currency);
    }

    /// @inheritdoc IPriceOracle
    function priceForLiquidation(
        Currency currency,
        PoolKey calldata key
    ) external view returns (uint256 usd1e18) {
        return _poolPrice(currency, key, true);
    }

    /// @inheritdoc IPriceOracle
    function record(
        PoolKey calldata key
    ) external {
        (, ICollateralPolicy.Tier tier,,) = policy.tokenConfig(key.currency0);
        if (tier != ICollateralPolicy.Tier.MEME) {
            (, tier,,) = policy.tokenConfig(key.currency1);
        }
        if (tier == ICollateralPolicy.Tier.MEME) recorder.record(key);
    }

    /// @inheritdoc IPriceOracle
    function decimals(
        Currency currency
    ) external view returns (uint8) {
        (,, uint8 tokenDecimals,) = policy.tokenConfig(currency);
        return tokenDecimals;
    }

    function _poolPrice(
        Currency currency,
        PoolKey calldata key,
        bool forLiquidation
    ) private view returns (uint256) {
        (, ICollateralPolicy.Tier tier,,) = policy.tokenConfig(currency);
        if (tier != ICollateralPolicy.Tier.MEME) return price(currency);

        PoolId poolId = key.toId();
        bool currency0 = key.currency0 == currency;
        if (!currency0 && !(key.currency1 == currency)) revert MemeCurrencyNotInPool(currency, poolId);

        (uint160 sqrtPriceX96, int24 spotTick,,) = recorder.stateView().getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert MemeSpotUnavailable(poolId);
        uint256 spot = _memePrice(currency, currency0, spotTick);

        try recorder.consult(poolId, 1800) returns (int24 twapTick) {
            uint256 twap = _memePrice(currency, currency0, twapTick);
            if (!forLiquidation) return spot < twap ? spot : twap;
            if (spot < FullMath.mulDiv(twap, 10_000 - TierPresets.MEME_CRASH_THRESHOLD_BPS, 10_000)) {
                return spot;
            }
            return twap;
        } catch {
            if (!forLiquidation) revert MemeTwapUnavailable(poolId);
            return FullMath.mulDiv(spot, 10_000 - TierPresets.MEME_STALE_HAIRCUT_BPS, 10_000);
        }
    }

    function _memePrice(
        Currency currency,
        bool currency0,
        int24 tick
    ) private view returns (uint256) {
        uint256 quoteRaw = PriceMath.quoteAtTick(tick, 10 ** uint256(this.decimals(currency)), currency0);
        Currency quote = policy.quote();
        return FullMath.mulDiv(quoteRaw, price(quote), 10 ** uint256(this.decimals(quote)));
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
}
