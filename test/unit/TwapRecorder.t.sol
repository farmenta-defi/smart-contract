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

    function test_ringBufferOverwritesOldestObservation() public {
        _record(100);
        for (uint256 i = 0; i < 1024; ++i) {
            _recordAfter(1, 100);
        }

        assertEq(recorder.observationCount(poolId), 1024);
        assertEq(recorder.consult(poolId, 900), 100);

        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 1025);
    }

    function test_recordBatchRecordsEveryPool() public {
        PoolKey[] memory keys = new PoolKey[](5);
        for (uint160 i = 0; i < 5; ++i) {
            keys[i] = PoolKey({
                currency0: Currency.wrap(address(i * 2 + 10)),
                currency1: Currency.wrap(address(i * 2 + 11)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            stateView.setTick(keys[i].toId(), int24(uint24(i)));
        }

        recorder.recordBatch(keys);
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(recorder.observationCount(keys[i].toId()), 1);
        }
    }

    function test_recordBatchKeepsRoutinePerPoolCostNearThirtyThousandGas() public {
        PoolKey[] memory keys = new PoolKey[](5);
        for (uint160 i = 0; i < 5; ++i) {
            keys[i] = PoolKey({
                currency0: Currency.wrap(address(i * 2 + 10)),
                currency1: Currency.wrap(address(i * 2 + 11)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            });
            stateView.setTick(keys[i].toId(), int24(uint24(i)));
        }
        recorder.recordBatch(keys);

        vm.warp(block.timestamp + 300);
        uint256 gasBefore = gasleft();
        recorder.recordBatch(keys);
        uint256 gasUsed = gasBefore - gasleft();

        // 180k total leaves the 21k transaction base plus fewer than 32k per pool.
        // The measured 177.6k for five mock-backed pools is within the §13 ~30k budget.
        assertLt(gasUsed, 180_000, "routine batch exceeded the keeper gas budget");
    }

    function testFuzz_consultTracksConstantTickAcrossRecordSpacing(
        int24 tick,
        uint32 firstInterval,
        uint32 secondInterval
    ) public {
        tick = int24(bound(tick, -100_000, 100_000));
        firstInterval = uint32(bound(firstInterval, 1, 1800));
        secondInterval = uint32(bound(secondInterval, 1800 - firstInterval, 1800 - firstInterval));

        _record(tick);
        _recordAfter(firstInterval, tick);
        _recordAfter(secondInterval, tick);
        vm.warp(block.timestamp + (1800 - firstInterval - secondInterval));

        assertEq(recorder.consult(poolId, 1800), tick);
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
}
