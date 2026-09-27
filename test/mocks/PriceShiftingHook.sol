// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Fork-test hook that moves its own pool's price around every liquidity addition.
/// @dev Install it at an address carrying `BEFORE_ADD_LIQUIDITY_FLAG` and
///      `AFTER_ADD_LIQUIDITY_FLAG`, and nothing else. Before the addition it sells currency0
///      into its pool until the price sits `pushSpacings` tick spacings below the pool's tick
///      snapped down onto the spacing, so the pool prices the addition there. After it, it
///      sells back the currency1 the push bought, now against the liquidity that was just
///      added, and takes the currency0 that comes back above what the push cost. Both swaps
///      settle against each other inside the adder's unlock, so the hook starts with nothing.
///      It returns no delta and touches no removal callback, which is why the 0x303 mask
///      admitted it (FAR-63).
///
///      Dormant until `arm` is called, so the same pool gives the control measurement.
contract PriceShiftingHook {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable poolManager;

    /// @notice How many tick spacings below its snapped tick the price is pushed before an
    ///         addition. Zero is dormant.
    int24 public pushSpacings;

    /// @dev What the push of the addition in progress sold and bought. Set in
    ///      `beforeAddLiquidity`, spent in `afterAddLiquidity`.
    uint128 internal sold0;
    uint128 internal bought1;

    error NotPoolManager();

    constructor(
        IPoolManager poolManager_
    ) {
        poolManager = poolManager_;
    }

    function arm(
        int24 pushSpacings_
    ) external {
        pushSpacings = pushSpacings_;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        int24 spacings = pushSpacings;
        if (spacings != 0) {
            (, int24 tick,,) = poolManager.getSlot0(key.toId());
            tick = _snapDown(tick, key.tickSpacing);
            // Exact input far beyond what the pool holds: the price limit is what stops it.
            BalanceDelta pushed = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(uint256(type(uint128).max)),
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(tick - spacings * key.tickSpacing)
                }),
                ""
            );
            sold0 = uint128(-pushed.amount0());
            bought1 = uint128(pushed.amount1());
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        uint128 bought = bought1;
        if (bought != 0) {
            BalanceDelta undone = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: -int256(uint256(bought)),
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            // currency1 nets to zero. An addition too small to pay the push back reverts here.
            poolManager.take(key.currency0, address(this), uint128(undone.amount0()) - sold0);
            delete sold0;
            delete bought1;
        }

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _snapDown(
        int24 tick,
        int24 spacing
    ) private pure returns (int24 snapped) {
        // Dividing before multiplying is the point: it snaps the tick down onto the spacing.
        // forge-lint: disable-next-line(divide-before-multiply)
        snapped = (tick / spacing) * spacing;
        if (tick < 0 && snapped != tick) snapped -= spacing;
    }
}
