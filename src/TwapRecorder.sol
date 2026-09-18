// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

/// @title TwapRecorder
/// @notice Permissionless tick-observation recorder for Uniswap v4 pools.
/// @dev StateView reads slot0 through Uniswap's StateLibrary. Recording uses the previous
///      tick for elapsed time, matching Uniswap v3's cumulative-observation convention.
contract TwapRecorder {
    uint16 public constant OBSERVATION_CAPACITY = 2048;
    uint32 public constant DEFAULT_WINDOW = 1800;
    uint32 public constant STALE_THRESHOLD = 900;

    error TwapUnavailable();

    struct Observation {
        uint64 timestamp;
        int56 tickCumulative;
    }

    struct PoolState {
        uint64 lastTimestamp;
        int56 tickCumulative;
        int24 lastTick;
        uint16 observationCount;
        uint16 latestIndex;
    }

    IStateView public immutable stateView;

    mapping(PoolId poolId => PoolState) internal _pools;
    mapping(PoolId poolId => mapping(uint16 index => Observation)) internal _observations;

    event Recorded(PoolId indexed poolId, uint16 index, uint64 timestamp, int56 tickCumulative);

    constructor(
        IStateView stateView_
    ) {
        stateView = stateView_;
    }

    /// @notice Records a pool's current tick if no observation exists for this timestamp.
    function record(
        PoolKey calldata key
    ) external {
        _record(key);
    }

    /// @notice Records each pool independently; repeated pools or same-block calls are no-ops.
    function recordBatch(
        PoolKey[] calldata keys
    ) external {
        for (uint256 i; i < keys.length; ++i) {
            _record(keys[i]);
        }
    }

    /// @notice Returns the 30-minute geometric TWAP tick for a pool.
    function consult(
        PoolId poolId
    ) external view returns (int24) {
        return _consult(poolId, DEFAULT_WINDOW);
    }

    /// @notice Returns the geometric TWAP tick over `window` seconds.
    function consult(
        PoolId poolId,
        uint32 window
    ) external view returns (int24) {
        return _consult(poolId, window);
    }

    function observationCount(
        PoolId poolId
    ) external view returns (uint16) {
        return _pools[poolId].observationCount;
    }

    function _record(
        PoolKey calldata key
    ) internal {
        PoolId poolId = key.toId();
        PoolState storage pool = _pools[poolId];
        uint64 timestamp = uint64(block.timestamp);
        if (pool.observationCount != 0 && pool.lastTimestamp == timestamp) return;

        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert TwapUnavailable();
        if (pool.observationCount == 0) {
            pool.lastTimestamp = timestamp;
            pool.lastTick = tick;
            pool.observationCount = 1;
            _observations[poolId][0] = Observation({timestamp: timestamp, tickCumulative: 0});
            emit Recorded(poolId, 0, timestamp, 0);
            return;
        }

        pool.tickCumulative += int56(pool.lastTick) * int56(uint56(timestamp - pool.lastTimestamp));
        uint16 index = pool.observationCount < OBSERVATION_CAPACITY ? pool.observationCount : _next(pool.latestIndex);
        if (pool.observationCount < OBSERVATION_CAPACITY) ++pool.observationCount;

        pool.latestIndex = index;
        pool.lastTimestamp = timestamp;
        pool.lastTick = tick;
        _observations[poolId][index] = Observation({timestamp: timestamp, tickCumulative: pool.tickCumulative});
        emit Recorded(poolId, index, timestamp, pool.tickCumulative);
    }

    function _consult(
        PoolId poolId,
        uint32 window
    ) internal view returns (int24) {
        PoolState storage pool = _pools[poolId];
        if (window == 0 || pool.observationCount == 0 || block.timestamp < window) revert TwapUnavailable();

        uint64 target = uint64(block.timestamp - window);
        Observation memory oldest = _observationAt(poolId, pool, 0);
        Observation memory latest = _observationAt(poolId, pool, pool.observationCount - 1);
        uint64 staleAt = block.timestamp > STALE_THRESHOLD ? uint64(block.timestamp - STALE_THRESHOLD) : 0;
        if (oldest.timestamp > target || latest.timestamp < staleAt) {
            revert TwapUnavailable();
        }

        int56 cumulativeNow = _currentCumulative(pool);
        int56 cumulativeThen = _cumulativeAt(poolId, pool, target, oldest, latest, cumulativeNow);
        int56 tickDelta = cumulativeNow - cumulativeThen;
        int56 divisor = int56(uint56(window));
        int56 twapTick = tickDelta / divisor;
        if (tickDelta < 0 && tickDelta % divisor != 0) --twapTick;
        return int24(twapTick);
    }

    /// @dev Interpolates between the two observations around `target` by dividing first, as
    ///      Uniswap v3's `Oracle.observeSingle` does. Multiplying first builds `tick × gap²` in
    ///      int56, which overflows once neighbouring observations are days apart (FAR-48: 5 days
    ///      at tick -200,000, 3 days at the maximum tick). The quotient is the tick that held
    ///      between the two, at most 887,272 in magnitude, so the product stays inside int56 for
    ///      as long as `tickCumulative` itself does. Nothing is lost to the division: `_record`
    ///      writes neighbours exactly `lastTick × elapsed` apart, so it leaves no remainder.
    function _cumulativeAt(
        PoolId poolId,
        PoolState storage pool,
        uint64 target,
        Observation memory oldest,
        Observation memory latest,
        int56 cumulativeNow
    ) internal view returns (int56) {
        if (target >= latest.timestamp) {
            return target == uint64(block.timestamp)
                ? cumulativeNow
                : latest.tickCumulative + int56(pool.lastTick) * int56(uint56(target - latest.timestamp));
        }

        if (target == oldest.timestamp) return oldest.tickCumulative;

        uint16 lowerOffset;
        uint16 upperOffset = pool.observationCount - 1;
        Observation memory lower = oldest;
        while (lowerOffset + 1 < upperOffset) {
            uint16 middleOffset = lowerOffset + (upperOffset - lowerOffset) / 2;
            Observation memory middle = _observationAt(poolId, pool, middleOffset);
            if (middle.timestamp <= target) {
                lowerOffset = middleOffset;
                lower = middle;
            } else {
                upperOffset = middleOffset;
            }
        }

        Observation memory upper = _observationAt(poolId, pool, upperOffset);
        if (target == upper.timestamp) return upper.tickCumulative;

        int56 tickBetween =
            (upper.tickCumulative - lower.tickCumulative) / int56(uint56(upper.timestamp - lower.timestamp));
        return lower.tickCumulative + tickBetween * int56(uint56(target - lower.timestamp));
    }

    function _currentCumulative(
        PoolState storage pool
    ) internal view returns (int56) {
        return pool.tickCumulative + int56(pool.lastTick) * int56(uint56(block.timestamp - pool.lastTimestamp));
    }

    function _observationAt(
        PoolId poolId,
        PoolState storage pool,
        uint16 offset
    ) internal view returns (Observation memory) {
        uint16 oldestIndex = pool.observationCount < OBSERVATION_CAPACITY ? 0 : _next(pool.latestIndex);
        return _observations[poolId][uint16((uint256(oldestIndex) + offset) % OBSERVATION_CAPACITY)];
    }

    function _next(
        uint16 index
    ) internal pure returns (uint16) {
        return index + 1 == OBSERVATION_CAPACITY ? 0 : index + 1;
    }
}
