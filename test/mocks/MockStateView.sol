// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Minimal StateView substitute for recorder unit tests.
/// @dev The recorder reads only slot0's tick, so modelling unrelated pool state here would
///      make the test fixture harder to audit without exercising more production behavior.
contract MockStateView {
    mapping(PoolId poolId => int24) internal _tick;

    function setTick(
        PoolId poolId,
        int24 tick
    ) external {
        _tick[poolId] = tick;
    }

    function getSlot0(
        PoolId poolId
    ) external view returns (uint160, int24 tick, uint24, uint24) {
        return (0, _tick[poolId], 0, 0);
    }
}
