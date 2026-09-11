// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
        PoolKey[] memory keys = _livePoolKeys();
        recorder.recordBatch(keys);

        vm.warp(block.timestamp + 300);
        uint256 gasBefore = gasleft();
        recorder.recordBatch(keys);
        uint256 gasUsed = gasBefore - gasleft();

        // This measures the recorder call body against the deployed StateView, excluding
        // transaction base and calldata. Keep the bound loose across Foundry stable bumps;
        // record the measured value in the PR against ARCHITECTURE.md §13's ~30k target.
        emit log_named_uint("routine recordBatch gas", gasUsed);
        assertLt(gasUsed, 500_000, "routine batch exceeded 100k gas per live pool");
    }

    function _livePoolKeys() private pure returns (PoolKey[] memory keys) {
        keys = new PoolKey[](5);
        keys[0] = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            fee: 0x800000,
            tickSpacing: 1,
            hooks: IHooks(Fixtures.HOOK_ETH_USDG_DYN)
        });
        keys[1] = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            fee: 460,
            tickSpacing: 9,
            hooks: IHooks(address(0))
        });
        keys[2] = PoolKey({
            currency0: Currency.wrap(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73),
            currency1: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            fee: 200,
            tickSpacing: 4,
            hooks: IHooks(address(0))
        });
        keys[3] = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(Fixtures.HOOK_ETH_USDG_TS60)
        });
        keys[4] = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
    }
}
