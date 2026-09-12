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
        uint256 gasBefore = gasleft();
        recorder.recordBatch(keys);
        uint256 gasUsed = gasBefore - gasleft();

        // This measures the recorder call body against the deployed StateView, excluding
        // transaction base and calldata. At ForkTest.FORK_BLOCK it measured 155,648 gas on
        // Foundry nightly and 221,184 on stable for these five pools. Keep the bound loose
        // across stable bumps; ARCHITECTURE.md §13 records the toolchain split and baseline.
        emit log_named_uint("routine recordBatch gas", gasUsed);
        assertLt(gasUsed, 500_000, "routine batch exceeded 100k gas per live pool");
    }
}
