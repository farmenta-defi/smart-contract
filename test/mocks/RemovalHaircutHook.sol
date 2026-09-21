// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Fork-test hook that keeps a fixed share of every removal payout.
/// @dev The test installs this runtime code at an address carrying v4's after-remove and return-
///      delta bits. `take` settles the hook's positive delta, so the PositionManager receives the
///      reduced amount that a reviewed production hook would actually leave behind.
contract RemovalHaircutHook {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant BPS = 10_000;

    IPoolManager internal immutable poolManager;
    uint16 internal immutable haircutBps;

    error NotPoolManager();

    constructor(
        IPoolManager poolManager_,
        uint16 haircutBps_
    ) {
        poolManager = poolManager_;
        haircutBps = haircutBps_;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();

        uint128 haircut0 = _haircut(delta.amount0());
        uint128 haircut1 = _haircut(delta.amount1());
        if (haircut0 != 0) poolManager.take(key.currency0, address(this), haircut0);
        if (haircut1 != 0) poolManager.take(key.currency1, address(this), haircut1);

        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(int128(haircut0), int128(haircut1)));
    }

    function _haircut(
        int128 amount
    ) private view returns (uint128) {
        return amount > 0 ? uint128(uint256(uint128(amount)) * haircutBps / BPS) : 0;
    }
}
