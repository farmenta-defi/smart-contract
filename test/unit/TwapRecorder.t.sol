// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {TwapRecorder} from "../../src/TwapRecorder.sol";
import {MockStateView} from "../mocks/MockStateView.sol";

contract TwapRecorderTest is Test {
    PoolKey internal key;
    PoolId internal poolId;
    MockStateView internal stateView;
    TwapRecorder internal recorder;

    function setUp() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = key.toId();
        stateView = new MockStateView();
        recorder = new TwapRecorder(IStateView(address(stateView)));
        vm.warp(1_000_000);
    }

    function test_firstRecordStoresObservationButCannotConsultYet() public {
        stateView.setTick(poolId, 100);
        vm.expectEmit(true, false, false, true);
        emit TwapRecorder.Recorded(poolId, 0, uint64(block.timestamp), 0);
        recorder.record(key);

        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 1800);
    }

    function test_consultReturnsTimeWeightedAverageOverThirtyMinutes() public {
        _record(100);
        _recordAfter(300, 200);
        _recordAfter(300, 50);
        _recordAfter(300, -100);
        _recordAfter(300, 400);
        _recordAfter(300, 100);
        _recordAfter(300, 100);

        assertEq(recorder.consult(poolId, 1800), 125);
        assertEq(recorder.consult(poolId), 125);
    }

    function test_consultLimitsOneTenXTickIntervalToOneSixthOfTheWindow() public {
        // ln(10) / ln(1.0001) rounds to 23,026 ticks. It applies for one of six
        // five-minute intervals, so the 30-minute geometric TWAP rises by 3,837 ticks.
        _record(0);
        _recordAfter(300, 23_026);
        _recordAfter(300, 0);
        _recordAfter(300, 0);
        _recordAfter(300, 0);
        _recordAfter(300, 0);
        _recordAfter(300, 0);

        assertEq(recorder.consult(poolId, 1800), 3837);
    }

    function test_secondRecordInSameTimestampIsIgnored() public {
        _record(100);
        _recordAfter(300, 200);
        uint16 beforeCount = recorder.observationCount(poolId);

        stateView.setTick(poolId, 300);
        recorder.record(key);

        assertEq(recorder.observationCount(poolId), beforeCount);
    }

    function test_RevertWhenLatestObservationIsStale() public {
        _record(100);
        _recordAfter(1800, 100);
        vm.warp(block.timestamp + 901);

        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 1800);
    }

    function test_RevertWhenHistoryIsShorterThanWindow() public {
        _record(100);
        _recordAfter(1799, 100);

        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 1800);
    }

    function test_RevertWhenPoolHasNoRecordedObservation() public {
        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 1800);
    }

    function test_RevertWhenConsultWindowIsZero() public {
        _record(100);
        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 0);
    }

    function test_consultInterpolatesObservationAtWindowStart() public {
        _record(100);
        _recordAfter(900, 300);
        _recordAfter(900, 200);
        _recordAfter(900, 200);
        vm.warp(block.timestamp + 450);

        // The start is halfway from t=900 to t=1800, where the cumulative tick is 225_000.
        // cumNow is 630_000, so the interpolated 1800-second average is 225.
        assertEq(recorder.consult(poolId, 1800), 225);
    }

    function test_consultRoundsNegativeFractionalTicksDown() public {
        _record(-50);
        _recordAfter(900, -51);
        _recordAfter(900, -51);

        assertEq(recorder.consult(poolId, 1800), -51);
    }

    function test_fullBufferRetainsThirtyMinuteHistory() public {
        assertEq(recorder.OBSERVATION_CAPACITY(), 2048);
        _record(100);
        for (uint256 i = 1; i < 2048; ++i) {
            _recordAfter(1, 100);
        }

        assertEq(recorder.consult(poolId, 1800), 100);
        assertEq(recorder.observationCount(poolId), 2048);
    }

    function test_ringBufferOverwritesOldestObservation() public {
        _record(100);
        for (uint256 i = 0; i < 2048; ++i) {
            _recordAfter(1, int24(uint24(100 + (i % 3))));
        }

        assertEq(recorder.consult(poolId, 2047), 100);
        assertEq(recorder.observationCount(poolId), 2048);

        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 2048);
    }

    function test_recordBatchRecordsEveryPool() public {
        PoolKey[] memory keys = _batchKeys();

        recorder.recordBatch(keys);
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(recorder.observationCount(keys[i].toId()), 1);
        }

        vm.warp(block.timestamp + 300);
        for (uint256 i = 0; i < keys.length; ++i) {
            stateView.setTick(keys[i].toId(), int24(uint24(100 + i)));
        }
        recorder.recordBatch(keys);
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(recorder.consult(keys[i].toId(), 300), int24(uint24(i)));
        }
    }

    function testFuzz_consultTracksConstantTickAcrossRecordSpacing(
        int24 tick,
        uint32 firstInterval
    ) public {
        tick = int24(bound(tick, -100_000, 100_000));
        firstInterval = uint32(bound(firstInterval, 1, 1800));
        uint32 secondInterval = 1800 - firstInterval;

        _record(tick);
        _recordAfter(firstInterval, tick);
        _recordAfter(secondInterval, tick);
        vm.warp(block.timestamp + (1800 - firstInterval - secondInterval));

        assertEq(recorder.consult(poolId, 1800), tick);
    }

    function testFuzz_consultMatchesWeightedTicks(
        int24[6] memory ticks,
        uint32[5] memory intervalSeeds
    ) public {
        uint256 remaining = 1800;
        int256 weightedTicks;
        for (uint256 i; i < 6; ++i) {
            ticks[i] = int24(bound(ticks[i], -100_000, 100_000));
        }

        _record(ticks[0]);
        for (uint256 i; i < 5; ++i) {
            uint256 interval = bound(intervalSeeds[i], 1, remaining - (4 - i));
            weightedTicks += int256(ticks[i]) * int256(interval);
            remaining -= interval;
            _recordAfter(interval, ticks[i + 1]);
        }
        weightedTicks += int256(ticks[5]) * int256(remaining);
        _recordAfter(remaining, ticks[5]);

        int256 expected = weightedTicks / 1800;
        if (weightedTicks < 0 && weightedTicks % 1800 != 0) --expected;
        assertEq(recorder.consult(poolId, 1800), int24(expected));
    }

    function _record(
        int24 tick
    ) internal {
        stateView.setTick(poolId, tick);
        recorder.record(key);
    }

    function _recordAfter(
        uint256 elapsed,
        int24 nextTick
    ) internal {
        vm.warp(block.timestamp + elapsed);
        _record(nextTick);
    }

    function _batchKeys() internal returns (PoolKey[] memory keys) {
        keys = new PoolKey[](5);
        for (uint160 i; i < 5; ++i) {
            keys[i] = PoolKey({
                currency0: Currency.wrap(address(i * 2 + 10)),
                currency1: Currency.wrap(address(i * 2 + 11)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            stateView.setTick(keys[i].toId(), int24(uint24(i)));
        }
    }
}
