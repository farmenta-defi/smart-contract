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
        recorder.record(key);
        vm.warp(block.timestamp + 1800);
        recorder.record(key);

        assertEq(recorder.consult(Fixtures.POOL_MEME_DOPPLER, 1800), tick);
    }
}
