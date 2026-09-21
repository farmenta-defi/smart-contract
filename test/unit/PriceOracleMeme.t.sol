// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TwapRecorder} from "../../src/TwapRecorder.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockStateView} from "../mocks/MockStateView.sol";

contract PriceOracleMemeTest is Test {
    Currency internal constant USDG = Currency.wrap(address(0x1001));
    Currency internal constant MEME = Currency.wrap(address(0x1002));
    address internal constant OWNER = address(0xA11CE);

    CollateralPolicy internal policy;
    PriceOracle internal oracle;
    TwapRecorder internal recorder;
    MockStateView internal stateView;
    MockAggregatorV3 internal usdgUsd;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        vm.warp(2_000_000);
        key = PoolKey({currency0: MEME, currency1: USDG, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});
        poolId = key.toId();

        policy = new CollateralPolicy(USDG, OWNER);
        usdgUsd = new MockAggregatorV3(8);
        usdgUsd.setAnswer(1e8, block.timestamp);
        vm.startPrank(OWNER);
        policy.setTokenConfig(USDG, true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(usdgUsd));
        policy.setTokenConfig(MEME, true, ICollateralPolicy.Tier.MEME, 18, address(0));
        vm.stopPrank();

        stateView = new MockStateView();
        recorder = new TwapRecorder(IStateView(address(stateView)));
        oracle = new PriceOracle(policy, recorder);
    }

    function test_borrowUsesTheLowerOfSpotAndTwap() public {
        _recordTwap(1.2e18);
        _setSpot(1e18);
        assertApproxEqRel(oracle.price(MEME, key), 1e18, 1e14);

        _setSpot(1.2e18);
        _recordTwap(1e18);
        assertApproxEqRel(oracle.price(MEME, key), 1e18, 1e14);
    }

    function test_liquidationUsesTwapUnlessSpotHasCrashed() public {
        _recordTwap(1.1e18);
        _setSpot(1e18);
        assertApproxEqRel(oracle.priceForLiquidation(MEME, key), 1.1e18, 1e14);

        _recordTwap(1e18);
        _setSpot(0.7e18);
        assertApproxEqRel(oracle.priceForLiquidation(MEME, key), 0.7e18, 1e14);
    }

    function test_liquidationTreatsTheCrashBoundaryAsExclusive() public {
        _recordTwap(1e18);
        _setSpot(0.75e18);
        assertApproxEqRel(oracle.priceForLiquidation(MEME, key), 1e18, 1e14);
    }

    function test_staleTwapBlocksBorrowAndHaircutsLiquidation() public {
        _setSpot(1e18);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.MemeTwapUnavailable.selector, poolId));
        oracle.price(MEME, key);
        assertApproxEqRel(oracle.priceForLiquidation(MEME, key), 0.8e18, 1e14);
    }

    function test_recordAfterATenDayGapRestoresTheTwap() public {
        // FAR-48: the consult behind this used to panic 0x11 for 30 minutes after such a
        // record, and the oracle read that as a stale TWAP.
        _recordTwap(1.1e18);
        vm.warp(block.timestamp + 10 days);
        usdgUsd.setAnswer(1e8, block.timestamp);
        _setSpot(1e18);
        assertApproxEqRel(oracle.priceForLiquidation(MEME, key), 0.8e18, 1e14);

        recorder.record(key);

        assertApproxEqRel(oracle.priceForLiquidation(MEME, key), 1.1e18, 1e14);
        assertApproxEqRel(oracle.price(MEME, key), 1e18, 1e14);
    }

    function test_recordStoresMemeObservations() public {
        _setSpot(1e18);
        oracle.record(key);
        assertEq(recorder.observationCount(poolId), 1);
    }

    function testFuzz_staleBoundaryIsExactlyNineHundredSeconds(
        uint256 elapsed
    ) public {
        elapsed = bound(elapsed, 0, 2000);
        _recordTwap(1e18);
        _setSpot(1e18);
        vm.warp(block.timestamp + elapsed);

        if (elapsed <= 900) {
            assertApproxEqRel(oracle.price(MEME, key), 1e18, 1e14);
        } else {
            vm.expectRevert(abi.encodeWithSelector(PriceOracle.MemeTwapUnavailable.selector, poolId));
            oracle.price(MEME, key);
        }
    }

    function _recordTwap(
        uint256 price
    ) private {
        int24 tick = _tick(price);
        stateView.setTick(poolId, tick);
        recorder.record(key);
        vm.warp(block.timestamp + 1800);
        recorder.record(key);
    }

    function _setSpot(
        uint256 price
    ) private {
        stateView.setTick(poolId, _tick(price));
    }

    function _tick(
        uint256 price
    ) private pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(PriceMath.derivedSqrtPriceX96(price, 1e18, 18, 6));
    }
}
