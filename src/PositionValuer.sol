// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IPositionValuer} from "./interfaces/IPositionValuer.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {PositionAmounts} from "./libraries/PositionAmounts.sol";
import {PriceMath} from "./libraries/PriceMath.sol";

/// @title PositionValuer
/// @notice Values Uniswap v4 LP positions at oracle prices (ARCHITECTURE §4.2, §5.1).
/// @dev Stateless and permissionless: it holds no funds, no risk parameters, and no owner.
///      `FarmentaMarket` stores its address as an immutable and changes it by upgrading, so
///      this contract needs no setter of its own.
///
///      The central choice is that token amounts are computed at a price **derived from
///      oracles**, not at the pool's spot price. A position pushed to one edge of its range
///      by a manipulated pool still values at what the oracles say it holds. The pool's own
///      price is read solely to report how far it has drifted, which the market turns into
///      the ±2% borrow gate of §5.2.
contract PositionValuer is IPositionValuer {
    using PositionInfoLibrary for PositionInfo;

    IPositionManager public immutable positionManager;
    IStateView public immutable stateView;
    IPriceOracle public immutable oracle;

    constructor(
        IPositionManager positionManager_,
        IStateView stateView_,
        IPriceOracle oracle_
    ) {
        positionManager = positionManager_;
        stateView = stateView_;
        oracle = oracle_;
    }

    /// @dev Split across helpers purely to stay within the EVM's stack limit; the sequence is
    ///      read position → derive price → split into amounts → add fees → price in USD.
    /// @inheritdoc IPositionValuer
    function value(
        uint256 tokenId
    ) external view returns (Valuation memory v) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        if (PositionInfo.unwrap(info) == 0) revert PositionNotFound(tokenId);

        PoolId poolId = key.toId();
        int24 tickLower = info.tickLower();
        int24 tickUpper = info.tickUpper();

        uint256 price0 = oracle.price(key.currency0);
        uint256 price1 = oracle.price(key.currency1);
        uint8 decimals0 = oracle.decimals(key.currency0);
        uint8 decimals1 = oracle.decimals(key.currency1);

        uint160 derivedSqrtPriceX96 = PriceMath.derivedSqrtPriceX96(price0, price1, decimals0, decimals1);

        (v.liquidity, v.fees0, v.fees1) = _positionState(poolId, tokenId, tickLower, tickUpper);
        (v.amount0, v.amount1) = PositionAmounts.forLiquidity(
            derivedSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            v.liquidity
        );

        v.principalUsd = _usd(v.amount0, price0, decimals0) + _usd(v.amount1, price1, decimals1);
        v.feesUsd = _usd(v.fees0, price0, decimals0) + _usd(v.fees1, price1, decimals1);

        (uint160 sqrtSpotX96,,,) = stateView.getSlot0(poolId);
        v.spotDeviationBps = PriceMath.spotDeviationBps(sqrtSpotX96, derivedSqrtPriceX96);
    }

    /// @dev One read of the position's pool-side state, feeding both the principal and the
    ///      fees. §5.1 takes `liq` from `getPositionInfo` and uses that same value for
    ///      `getAmountsForLiquidity` and for the fee delta; reading liquidity twice — once
    ///      here and once from `PositionManager` — would cost an extra call and leave room
    ///      for principal and fees to be computed against different liquidity.
    ///
    ///      Uncollected fees exist in v4 only as a fee-growth delta — there is no
    ///      `tokensOwed` — so both the pool's current growth and the position's cached
    ///      growth are needed to recover them.
    function _positionState(
        PoolId poolId,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint128 liquidity, uint256 fees0, uint256 fees1) {
        bytes32 positionKey =
            Position.calculatePositionKey(address(positionManager), tickLower, tickUpper, bytes32(tokenId));

        uint256 growth0Last;
        uint256 growth1Last;
        (liquidity, growth0Last, growth1Last) = stateView.getPositionInfo(poolId, positionKey);

        (uint256 growth0, uint256 growth1) = stateView.getFeeGrowthInside(poolId, tickLower, tickUpper);
        (fees0, fees1) = PositionAmounts.feesOwed(growth0, growth1, growth0Last, growth1Last, liquidity);
    }

    /// @dev Raw token amount to USD at 1e18. The division by the token's decimals is where
    ///      USDG's 6 and ETH's 18 stop being interchangeable; `mulDiv` carries the 512-bit
    ///      intermediate so a large balance of an 18-decimal token cannot overflow on the way.
    function _usd(
        uint256 amount,
        uint256 priceUsd1e18,
        uint8 decimals
    ) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, priceUsd1e18, 10 ** uint256(decimals));
    }
}
