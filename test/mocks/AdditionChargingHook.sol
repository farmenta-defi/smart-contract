// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Fork-test hook that bills a fixed share of every liquidity addition to whoever adds.
/// @dev Install it at an address carrying `AFTER_ADD_LIQUIDITY_FLAG` and
///      `AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG`, and nothing else. v4-core subtracts the
///      returned delta from the caller's, so PositionManager settles the charge on top of
///      what the liquidity costs, up to the caller's maxima. `take` pays the hook, so the
///      charge ends up here and never in the position. It touches no removal callback, which
///      is why the 0x301 mask admitted it (FAR-47).
contract AdditionChargingHook {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant BPS = 10_000;

    IPoolManager internal immutable poolManager;
    uint16 internal immutable chargeBps;

    error NotPoolManager();

    constructor(
        IPoolManager poolManager_,
        uint16 chargeBps_
    ) {
        poolManager = poolManager_;
        chargeBps = chargeBps_;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        uint128 charge0 = _charge(delta.amount0());
        uint128 charge1 = _charge(delta.amount1());
        if (charge0 != 0) poolManager.take(key.currency0, address(this), charge0);
        if (charge1 != 0) poolManager.take(key.currency1, address(this), charge1);

        return (IHooks.afterAddLiquidity.selector, toBalanceDelta(int128(charge0), int128(charge1)));
    }

    /// @dev An addition owes the pool, so its amounts are negative.
    function _charge(
        int128 amount
    ) private view returns (uint128) {
        return amount < 0 ? uint128(uint256(uint128(-amount)) * chargeBps / BPS) : 0;
    }
}
