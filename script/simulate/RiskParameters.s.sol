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
    // Measured by the fork PoC in MarketMemeLiquidateForkTest at block 54_200_000.
    uint256 internal constant LIQUIDATION_GAS = 262_444;
    uint256 internal constant ROUTING_SLIPPAGE_BPS = 100;
    address internal constant SIMULATOR = address(0xFA422);
    uint80 internal constant FIRST_ETH_ROUND = (1 << 64) + 1;
    uint80 internal constant LAST_ETH_ROUND = (1 << 64) + 1992;

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
        _simulateChainlinkHistory();
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
        console.log("ltv blue collateral drop-to-LT bps", BPS - uint256(blue.maxLtvBps) * BPS / blue.ltBps);
        console.log("ltv meme collateral drop-to-LT bps", BPS - uint256(meme.maxLtvBps) * BPS / meme.ltBps);
        console.log("ltv measurement cadence seconds", OBSERVATION_SECONDS);
    }

    function _simulateChainlinkHistory() private view {
        uint256 count = uint256(LAST_ETH_ROUND - FIRST_ETH_ROUND + 1);
        uint256[] memory timestamps = new uint256[](count);
        uint256[] memory prices = new uint256[](count);
        (, int256 first,, uint256 firstAt,) = ethUsd.getRoundData(FIRST_ETH_ROUND);
        for (uint256 i; i < count; ++i) {
            (, int256 answer, uint256 startedAt,,) = ethUsd.getRoundData(FIRST_ETH_ROUND + uint80(i));
            timestamps[i] = startedAt;
            prices[i] = uint256(answer);
        }
        uint256 lastIndex = count - 1;
        (uint256 crossedPositions, uint256 delaySum, uint256 delayMin, uint256 delayMax, uint256 worstDrop) =
            _historyCrossings(prices, timestamps, lastIndex);
        (, int256 last,, uint256 lastAt,) = ethUsd.getRoundData(LAST_ETH_ROUND);
        console.log("chainlink history rounds", uint256(LAST_ETH_ROUND - FIRST_ETH_ROUND + 1));
        console.log("chainlink history seconds", lastAt - firstAt);
        console.log("chainlink first price (8 decimals)", uint256(first));
        console.log("chainlink last price (8 decimals)", uint256(last));
        console.log("chainlink maxLTV positions crossing HF 1", crossedPositions);
        console.log("chainlink maxLTV crossing percentage bps", crossedPositions * BPS / count);
        console.log("chainlink crossing delay average seconds", crossedPositions == 0 ? 0 : delaySum / crossedPositions);
        console.log("chainlink crossing delay minimum seconds", crossedPositions == 0 ? 0 : delayMin);
        console.log("chainlink crossing delay maximum seconds", delayMax);
        console.log("chainlink peak-to-trough drawdown bps", worstDrop);
        console.log("chainlink worst 1h drawdown bps", _worstWindowDrop(prices, timestamps, lastIndex, 1 hours));
        console.log("chainlink worst 24h drawdown bps", _worstWindowDrop(prices, timestamps, lastIndex, 24 hours));
    }

    function _historyCrossings(
        uint256[] memory prices,
        uint256[] memory timestamps,
        uint256 lastIndex
    ) private pure returns (uint256 crossed, uint256 delaySum, uint256 delayMin, uint256 delayMax, uint256 worstDrop) {
        delayMin = type(uint256).max;
        uint256 peak = prices[0];
        for (uint256 i; i <= lastIndex; ++i) {
            if (prices[i] > peak) peak = prices[i];
            uint256 drawdown = prices[i] < peak ? BPS - prices[i] * BPS / peak : 0;
            if (drawdown > worstDrop) worstDrop = drawdown;
            uint256 threshold =
                prices[i] * uint256(TierPresets.blueChip().maxLtvBps) / uint256(TierPresets.blueChip().ltBps);
            for (uint256 j = i + 1; j <= lastIndex; ++j) {
                if (timestamps[j] < timestamps[i]) continue;
                if (timestamps[j] - timestamps[i] > 24 hours) break;
                if (prices[j] < threshold) {
                    crossed++;
                    uint256 delay = timestamps[j] - timestamps[i];
                    delaySum += delay;
                    if (delay < delayMin) delayMin = delay;
                    if (delay > delayMax) delayMax = delay;
                    break;
                }
            }
        }
    }

    function _worstWindowDrop(
        uint256[] memory prices,
        uint256[] memory timestamps,
        uint256 lastIndex,
        uint256 window
    ) private pure returns (uint256 worst) {
        for (uint256 i; i <= lastIndex; ++i) {
            uint256 oldest = prices[i];
            for (uint256 j = i + 1; j <= lastIndex; ++j) {
                if (timestamps[j] < timestamps[i]) continue;
                if (timestamps[j] - timestamps[i] > window) break;
                if (prices[j] < oldest) oldest = prices[j];
            }
            uint256 relative = oldest * BPS / prices[i];
            uint256 drop = relative < BPS ? BPS - relative : 0;
            if (drop > worst) worst = drop;
        }
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
        console.log("basefee wei", block.basefee);
        console.log("blue profitable debt floor usd (1e18)", _minimumDebt(gasUsd, blue.minLiquidatorBonusBps));
        console.log("meme profitable debt floor usd (1e18)", _minimumDebt(gasUsd, meme.minLiquidatorBonusBps));
        console.log(
            "blue profitable position floor usd (1e18)",
            _minimumPosition(gasUsd, blue.minLiquidatorBonusBps, blue.maxLtvBps)
        );
        console.log(
            "meme profitable position floor usd (1e18)",
            _minimumPosition(gasUsd, meme.minLiquidatorBonusBps, meme.maxLtvBps)
        );
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
        TierPresets.Preset memory meme = TierPresets.meme();
        uint256 cap = uint256(meme.maxDebtCapUsdg) * 1e12;
        uint256 attackProfitAtCap = cap * (BPS + meme.minLiquidatorBonusBps) / BPS * BPS / TARGET_DUMP_BPS - cap - cap
            * (meme.minLiquidatorBonusBps / 10) / BPS;
        console.log("flash dump attack profit at meme cap usd (1e18)", attackProfitAtCap);
    }

    function _simulateBadDebt() private pure {
        TierPresets.Preset memory meme = TierPresets.meme();
        uint256 debtUsd = uint256(meme.maxDebtCapUsdg) * 1e12;
        uint256 collateralAtLt = debtUsd * BPS / meme.ltBps;
        uint256 reserveFloor = uint256(meme.marketDebtCapUsdg) * 250 * 1e12 / BPS;
        uint256[4] memory depths = [uint256(5000), 7500, 9000, 9900];
        for (uint256 i; i < depths.length; ++i) {
            uint256 rugBps = depths[i];
            uint256 collateral = collateralAtLt * (BPS - rugBps) / BPS;
            uint256 repayable = collateral * BPS / (BPS + meme.minLiquidatorBonusBps);
            uint256 badDebt = repayable >= debtUsd ? 0 : debtUsd - repayable;
            console.log("rug depth bps", rugBps);
            console.log("rug bad debt usd (1e18)", badDebt);
            console.log(
                "lender share-price loss bps (market cap denominator)", badDebt * BPS / uint256(meme.marketDebtCapUsdg)
            );
        }
        console.log("meme reserve floor reference usd (1e18)", reserveFloor);
    }

    function _minimumDebt(
        uint256 gasUsd,
        uint16 grossBonusBps
    ) private pure returns (uint256) {
        uint256 netBonusBps = grossBonusBps * 9 / 10;
        return FullMath.mulDiv(gasUsd, BPS, netBonusBps - ROUTING_SLIPPAGE_BPS);
    }

    function _minimumPosition(
        uint256 gasUsd,
        uint16 grossBonusBps,
        uint16 maxLtvBps
    ) private pure returns (uint256) {
        return FullMath.mulDiv(_minimumDebt(gasUsd, grossBonusBps), BPS, maxLtvBps);
    }

    function _gasUsd(
        uint256 gasUnits
    ) private view returns (uint256) {
        (, int256 ethAnswer,,,) = ethUsd.latestRoundData();
        return FullMath.mulDiv(gasUnits * block.basefee, uint256(ethAnswer) * 1e10, 1e18);
    }

    function _ethToUsd(
        uint256 ethAmount
    ) private view returns (uint256) {
        (, int256 ethAnswer,,,) = ethUsd.latestRoundData();
        return FullMath.mulDiv(ethAmount, uint256(ethAnswer) * 1e10, 1e18);
    }
}
