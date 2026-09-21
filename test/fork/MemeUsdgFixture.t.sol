// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice Pins the FAR-58 meme/USDG census fixture to reproducible live state.
contract MemeUsdgFixtureForkTest is ForkTest {
    function test_memeUsdgFixtureHasLiveSlot0AndLiquidity() public view {
        PoolKey memory key = Fixtures.memeUsdgKey();
        PoolId poolId = key.toId();

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(Fixtures.POOL_MEME_USDG), "fixture key has wrong id");

        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(poolId);
        assertEq(sqrtPriceX96, 79_228_162_514_264_337_593_380_708_632, "pinned sqrt price changed");
        assertEq(tick, -1, "pinned tick changed");
        assertEq(stateView.getLiquidity(poolId), 1_000_000_000_000_000_000_054_407_651, "pinned liquidity changed");
    }
}
