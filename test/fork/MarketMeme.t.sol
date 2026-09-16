// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TwapRecorder} from "../../src/TwapRecorder.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";
import {MockPyth} from "../mocks/MockPyth.sol";

/// @notice The meme oracle's recorder route against the live pools.trade/Doppler fixture.
contract MarketMemeForkTest is ForkTest {
    address internal constant OWNER = address(0xA11CE);

    TwapRecorder internal recorder;
    PriceOracle internal oracle;

    function setUp() public override {
        super.setUp();
        CollateralPolicy policy = new CollateralPolicy(Fixtures.memeDopplerKey().currency1, OWNER);
        PoolKey memory key = Fixtures.memeDopplerKey();
        vm.prank(OWNER);
        policy.setTokenConfig(key.currency0, true, ICollateralPolicy.Tier.MEME, 18, address(0));
        recorder = new TwapRecorder(stateView);
        oracle = new PriceOracle(policy, new MockPyth(), recorder);
    }

    function test_oracleRecordsTheMemePoolFixture() public {
        PoolKey memory key = Fixtures.memeDopplerKey();
        PoolId poolId = key.toId();
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(Fixtures.POOL_MEME_DOPPLER), "wrong meme fixture");

        oracle.record(key);
        assertEq(recorder.observationCount(poolId), 1, "meme record was not forwarded");
    }
}
