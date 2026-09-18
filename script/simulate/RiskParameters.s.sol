// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../../test/base/Fixtures.sol";

/// @title RiskParameters
/// @notice Reproducible, fork-backed measurements for ARCHITECTURE §5.3 and §6.2.
/// @dev Run `make simulate-risk`. The fork block and pool keys intentionally match ForkTest
///      and Fixtures, so a changed fixture is a reviewable input change rather than hidden data.
contract RiskParameters is Script {
    uint256 internal constant FORK_BLOCK = 54_200_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant OBSERVATIONS = 6;
    uint256 internal constant OBSERVATION_SECONDS = 300;
    uint256 internal constant TARGET_DUMP_BPS = 7500;
    uint256 internal constant MAX_SWAP_INPUT = 1_000_000 ether;
    uint256 internal constant GAS_PRICE_WEI = 0.02 gwei;
    uint256 internal constant LIQUIDATION_GAS = 750_000;
    uint256 internal constant ROUTING_SLIPPAGE_BPS = 100;
    address internal constant SIMULATOR = address(0xFA422);

    IStateView private stateView;
    IERC20 private usdg;
    IAggregatorV3 private ethUsd;

    function run() external {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        stateView = IStateView(RobinhoodChain.STATE_VIEW);
        usdg = IERC20(RobinhoodChain.USDG);
        ethUsd = IAggregatorV3(RobinhoodChain.CHAINLINK_ETH_USD);

        _printForkInputs();
        _simulateLtvBuffers();
        _simulateTwapPump();
        _simulateLiquidatorFloor();
        _simulateFlashDump();
        _simulateBadDebt();
    }

    function _printForkInputs() private view {
        PoolId[] memory ids = Fixtures.liveRecorderPoolIds();
        console.log("FAR-22 risk simulation");
        console.log("fork block", FORK_BLOCK);
        for (uint256 i; i < ids.length; ++i) {
            (, int24 tick,,) = stateView.getSlot0(ids[i]);
            console.log("pool index", i);
            console.log("pool tick", int256(tick));
            console.log("pool active liquidity", stateView.getLiquidity(ids[i]));
        }
    }

    function _simulateLtvBuffers() private pure {
        TierPresets.Preset memory blue = TierPresets.blueChip();
        TierPresets.Preset memory meme = TierPresets.meme();
        console.log("ltv blue drop-to-LT bps", (blue.ltBps - blue.maxLtvBps) * BPS / blue.maxLtvBps);
        console.log("ltv meme drop-to-LT bps", (meme.ltBps - meme.maxLtvBps) * BPS / meme.maxLtvBps);
        console.log("ltv measurement cadence seconds", OBSERVATION_SECONDS);
    }

    function _simulateTwapPump() private pure {
        // log_1.0001(10), floored: one 300-second pump interval in a six-interval window.
        int24 pumpTick = 23_027;
        int24 averageTick = pumpTick / int24(uint24(OBSERVATIONS));
        uint256 multiplierBps = PriceMath.quoteAtTick(averageTick, BPS, true);
        console.log("twap pump tick", int256(pumpTick));
        console.log("twap average tick", int256(averageTick));
        console.log("twap 10x-one-of-six multiplier bps", multiplierBps);
    }

    function _simulateLiquidatorFloor() private view {
        uint256 gasUsd = _gasUsd(LIQUIDATION_GAS);
        TierPresets.Preset memory blue = TierPresets.blueChip();
        TierPresets.Preset memory meme = TierPresets.meme();
        console.log("liquidator gas usd (1e18)", gasUsd);
        console.log("blue profitable position floor usd (1e18)", _minimumPosition(gasUsd, blue.minLiquidatorBonusBps));
        console.log("meme profitable position floor usd (1e18)", _minimumPosition(gasUsd, meme.minLiquidatorBonusBps));
        console.log("spec minimum position usd (1e18)", blue.minPositionUsd);
    }

    function _simulateFlashDump() private {
        PoolKey memory key = Fixtures.liveRecorderPoolKeys()[1];
        PoolId poolId = key.toId();
        (uint160 beforeSqrt, int24 beforeTick,,) = stateView.getSlot0(poolId);
        uint256 usdgBefore = usdg.balanceOf(SIMULATOR);

        vm.deal(SIMULATOR, MAX_SWAP_INPUT);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(RobinhoodChain.POOL_MANAGER));
        uint160 dumpLimit = uint160(FullMath.mulDiv(beforeSqrt, Math.sqrt(TARGET_DUMP_BPS * 1e14), 1e9));
        vm.prank(SIMULATOR);
        router.swap{value: MAX_SWAP_INPUT}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(MAX_SWAP_INPUT), sqrtPriceLimitX96: dumpLimit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 dumpedSqrt, int24 dumpedTick,,) = stateView.getSlot0(poolId);

        uint256 acquiredUsdg = usdg.balanceOf(SIMULATOR) - usdgBefore;
        vm.prank(SIMULATOR);
        usdg.approve(address(router), acquiredUsdg);
        vm.prank(SIMULATOR);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(acquiredUsdg),
                sqrtPriceLimitX96: uint160(TickMath.MAX_SQRT_PRICE - 1)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (, int24 restoredTick,,) = stateView.getSlot0(poolId);
        uint256 roundTripLossUsd = _ethToUsd(MAX_SWAP_INPUT - SIMULATOR.balance);
        console.log("flash dump pool tick before", int256(beforeTick));
        console.log("flash dump pool tick at target", int256(dumpedTick));
        console.log("flash dump achieved price drop bps", PriceMath.spotDeviationBps(dumpedSqrt, beforeSqrt));
        console.log("flash dump pool tick after restore", int256(restoredTick));
        console.log("flash dump round-trip loss usd (1e18)", roundTripLossUsd);
        console.log("meme cap bonus usd (1e18)", uint256(2000e18));
    }

    function _simulateBadDebt() private pure {
        uint256 debtUsd = 20_000e18;
        uint256 collateralAtLt = debtUsd * BPS / 4000;
        uint256 postRugCollateral = collateralAtLt * 2500 / BPS;
        uint256 repayable = postRugCollateral * BPS / 11_000;
        uint256 badDebt = debtUsd - repayable;
        console.log("meme rug collateral after 75pct loss usd (1e18)", postRugCollateral);
        console.log("meme rug bad debt usd (1e18)", badDebt);
        console.log("meme reserve floor at 50k total-assets usd (1e18)", uint256(1250e18));
    }

    function _minimumPosition(
        uint256 gasUsd,
        uint16 grossBonusBps
    ) private pure returns (uint256) {
        uint256 netBonusBps = grossBonusBps * 9 / 10;
        return FullMath.mulDiv(gasUsd, BPS, netBonusBps - ROUTING_SLIPPAGE_BPS);
    }

    function _gasUsd(
        uint256 gasUnits
    ) private view returns (uint256) {
        (, int256 ethAnswer,,,) = ethUsd.latestRoundData();
        return FullMath.mulDiv(gasUnits * GAS_PRICE_WEI, uint256(ethAnswer) * 1e10, 1e18);
    }

    function _ethToUsd(
        uint256 ethAmount
    ) private view returns (uint256) {
        (, int256 ethAnswer,,,) = ethUsd.latestRoundData();
        return FullMath.mulDiv(ethAmount, uint256(ethAnswer) * 1e10, 1e18);
    }
}
