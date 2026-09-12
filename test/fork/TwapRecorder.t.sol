// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TwapRecorder} from "../../src/TwapRecorder.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice Exercises recorder reads against the deployed Robinhood StateView and a meme pool.
contract TwapRecorderForkTest is ForkTest {
    TwapRecorder internal recorder;

    function setUp() public override {
        super.setUp();
        recorder = new TwapRecorder(stateView);
    }

    function test_recordsMemePoolAndReturnsItsLiveTick() public {
        PoolKey memory key = Fixtures.memeDopplerKey();
        assertEq(
            PoolId.unwrap(key.toId()),
            PoolId.unwrap(Fixtures.POOL_MEME_DOPPLER),
            "fixture key no longer identifies the meme pool"
        );

        (, int24 tick,,) = stateView.getSlot0(Fixtures.POOL_MEME_DOPPLER);
        assertEq(tick, 140_445, "pinned meme-pool tick changed");
        recorder.record(key);
        vm.warp(block.timestamp + 1800);
        recorder.record(key);

        assertEq(recorder.consult(Fixtures.POOL_MEME_DOPPLER, 1800), tick);
    }

    function test_recordBatchMeasuresFiveLivePoolsBelowOneHundredThousandGasPerPool() public {
        PoolKey[] memory keys = Fixtures.liveRecorderPoolKeys();
        PoolId[] memory ids = Fixtures.liveRecorderPoolIds();
        for (uint256 i; i < keys.length; ++i) {
            assertEq(
                PoolId.unwrap(keys[i].toId()),
                PoolId.unwrap(ids[i]),
                "live recorder key no longer identifies its expected pool"
            );
        }
        recorder.recordBatch(keys);

        vm.warp(block.timestamp + 300);
        vm.cool(address(recorder));
        vm.cool(address(stateView));
        vm.cool(address(poolManager));
        uint256 gasBefore = gasleft();
        recorder.recordBatch(keys);
        uint256 bufferFillGas = gasBefore - gasleft();

        uint256 capacity = recorder.OBSERVATION_CAPACITY();
        for (uint256 i = 2; i < capacity; ++i) {
            vm.warp(block.timestamp + 300);
            recorder.recordBatch(keys);
        }

        vm.warp(block.timestamp + 300);
        vm.cool(address(recorder));
        vm.cool(address(stateView));
        vm.cool(address(poolManager));
        gasBefore = gasleft();
        recorder.recordBatch(keys);
        uint256 steadyStateGas = gasBefore - gasleft();

        // This measures the recorder call body against the deployed StateView, excluding
        // transaction base and calldata. The measured batch costs are about 190k while filling
        // fresh observation slots and 102k after the buffer wraps. Keep loose 2x ceilings so
        // toolchain and fork-account-access variance does not recreate FAR-25's false failure;
        // the phase split still catches an order-of-magnitude regression in either path.
        emit log_named_uint("buffer-fill recordBatch gas", bufferFillGas);
        emit log_named_uint("steady-state recordBatch gas", steadyStateGas);
        assertLt(bufferFillGas, 2 * 189_648, "buffer-fill batch exceeded loose regression ceiling");
        assertLt(steadyStateGas, 2 * 102_338, "steady-state batch exceeded loose regression ceiling");
    }
}
