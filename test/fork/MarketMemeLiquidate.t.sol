// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {MarketLens} from "../../src/MarketLens.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {TwapRecorder} from "../../src/TwapRecorder.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {MarketLiquidation} from "../../src/libraries/MarketLiquidation.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice §5.3's liquidation price on a meme market, with nothing between the gate and the
///         pool: the real `PriceOracle` over a real `TwapRecorder`, FAR-49.
/// @dev The other market suites price through `MockPriceOracle`, which has no recorder behind
///      it, so none of them can tell a fresh TWAP from a stale one. Here the plain ETH/USDG
///      pool is listed as meme (native ETH re-tiered, §6.1 takes the higher tier), its TWAP is
///      the recorder's, and the only substitute left is the Chainlink USDG feed.
///
///      The pool does not move at the pinned block, so spot and TWAP agree while the recorder is
///      fresh. What separates the first two states below is the recorder alone: fresh, the gate
///      prices ETH at the TWAP; 901 seconds without an observation, at `spot × 0,8`. The third
///      moves the pool with a real swap, 30% down, which is past `crashThreshold`.
contract MarketMemeLiquidateForkTest is MarketForkTest {
    uint256 internal constant STALE_AFTER = 900;

    address internal lender = address(0x1E4DE2);
    address internal liquidator = address(0x11D);

    Currency internal constant ETH = Currency.wrap(RobinhoodChain.NATIVE);

    TwapRecorder internal recorder;
    PriceOracle internal memeOracle;
    PositionValuer internal memeValuer;
    FarmentaMarket internal memeMarket;
    MarketLens internal memeLens;
    MockAggregatorV3 internal usdgFeed;

    IERC20 internal usdg;
    uint256 internal tokenId;
    address internal borrower;
    PoolKey internal key;
    PoolId internal poolId;

    /// @dev Leaves the fixture borrowed against and aged to a health factor just above 1 on a
    ///      fresh TWAP: healthy where the recorder is fresh, and close enough to the line that
    ///      §5.3's 20% haircut alone puts it under.
    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_IN_RANGE;
        borrower = IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);
        usdg = IERC20(RobinhoodChain.USDG);
        key = _keyOf(tokenId);
        poolId = key.toId();

        usdgFeed = new MockAggregatorV3(8);
        usdgFeed.setAnswer(1e8, block.timestamp);

        vm.startPrank(owner);
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.USDG), true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(usdgFeed)
        );
        policy.setTokenConfig(ETH, true, ICollateralPolicy.Tier.MEME, 18, address(0));
        vm.stopPrank();

        recorder = new TwapRecorder(stateView);
        memeOracle = new PriceOracle(policy, recorder);
        memeValuer = new PositionValuer(positionManager, stateView, memeOracle);
        memeMarket = _deployMemeMarket();
        memeLens = new MarketLens(memeMarket);

        _listAsMeme();
        _observeFor(1800);

        vm.startPrank(borrower);
        IERC721(RobinhoodChain.POSITION_MANAGER).approve(address(memeMarket), tokenId);
        memeMarket.depositCollateral(tokenId);
        vm.stopPrank();

        // Barely more than the borrower takes, so utilisation is high and interest does the
        // ageing below in days rather than years.
        uint256 amount = memeLens.maxBorrow(tokenId);
        deal(address(usdg), lender, amount * 11 / 10);
        vm.startPrank(lender);
        usdg.approve(address(memeMarket), type(uint256).max);
        memeMarket.deposit(amount * 11 / 10, lender);
        vm.stopPrank();

        vm.prank(borrower);
        memeMarket.borrow(tokenId, amount, borrower);

        deal(address(usdg), liquidator, 10 * amount);
        vm.prank(liquidator);
        usdg.approve(address(memeMarket), type(uint256).max);

        _ageUntilHealthFactorBelow(1.02e18);
    }

    /* ------------------------------- fresh recorder --------------------------- */

    /// @notice The control: on a fresh TWAP the fixture is healthy, and the gate says so with the
    ///         same number the recorder's state gives a `view`.
    function test_aFreshTwapPricesTheGateAtTheTwap() public {
        uint256 viewed = memeLens.liquidationHealthFactor(tokenId);
        assertGe(viewed, 1e18, "the fixture should be healthy on a fresh TWAP");

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.PositionIsHealthy.selector, tokenId, viewed));
        memeMarket.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
    }

    /* -------------------------------- stale recorder -------------------------- */

    /// @notice §5.3 v0.52, the acceptance case: 901 seconds without an observation, the gate
    ///         prices ETH at `spot × 0,8`, and a position that the TWAP called healthy goes.
    function test_aStaleTwapLiquidatesAtTheHaircutSpot() public {
        uint256 twapPrice = memeOracle.priceForLiquidation(ETH, key);
        assertGe(memeLens.liquidationHealthFactor(tokenId), 1e18, "the fixture should be healthy on a fresh TWAP");

        _goStale();

        vm.expectRevert(TwapRecorder.TwapUnavailable.selector);
        recorder.consult(poolId, 1800);
        assertEq(
            memeOracle.priceForLiquidation(ETH, key),
            FullMath.mulDiv(twapPrice, 8000, 10_000),
            "stale mode prices ETH at spot x 0,8"
        );
        assertLt(memeLens.liquidationHealthFactor(tokenId), 1e18, "and at that price the fixture is under water");

        uint256 debt = memeMarket.debtOf(tokenId);
        vm.prank(liquidator);
        (uint256 repaid,,,) = memeMarket.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "the gate let the liquidation through");
        assertLt(memeMarket.debtOf(tokenId), debt, "and the debt came down");
    }

    /// @notice What a `view` reads and what the gate reads are the same recorder state, so they
    ///         cannot disagree: under 1 exactly when `liquidate` does not answer
    ///         `PositionIsHealthy` (FAR-43's meme acceptance case, which this unblocks).
    function test_theGateAgreesWithAViewOfTheSameState() public {
        assertGe(memeLens.liquidationHealthFactor(tokenId), 1e18, "fresh: a view reads healthy");
        assertFalse(_liquidates(), "fresh: and the gate refuses");

        _goStale();

        assertLt(memeLens.liquidationHealthFactor(tokenId), 1e18, "stale: a view reads under water");
        assertTrue(_liquidates(), "stale: and the gate lets it through");
    }

    /// @notice The liquidation still feeds the recorder, only afterwards: one new observation,
    ///         and with it the TWAP is back for whoever comes next.
    function test_aStaleLiquidationLeavesAnObservationBehind() public {
        _goStale();
        uint256 observations = recorder.observationCount(poolId);

        vm.prank(liquidator);
        memeMarket.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(recorder.observationCount(poolId), observations + 1, "one observation, after the seizure");
        recorder.consult(poolId, 1800);
    }

    /* ---------------------------------- a crash ------------------------------- */

    /// @notice §5.2: spot more than `crashThreshold` under a TWAP that has not caught up, so the
    ///         gate prices at spot. The recorder is fresh throughout, and the record's place
    ///         makes no difference here; this is the third state the gate and a view of it have
    ///         to agree in.
    function test_aCrashPastTheThresholdLiquidatesAtSpot() public {
        uint256 twapPrice = memeOracle.priceForLiquidation(ETH, key);
        assertGe(memeLens.liquidationHealthFactor(tokenId), 1e18, "the fixture should be healthy before the crash");

        _sellEthUntilSpotIs(7000);

        recorder.consult(poolId, 1800);
        assertEq(
            memeOracle.priceForLiquidation(ETH, key),
            memeOracle.price(ETH, key),
            "with the TWAP still valid, liquidation reads spot, as borrowing's min(spot, TWAP) does"
        );
        assertLt(
            memeOracle.priceForLiquidation(ETH, key),
            FullMath.mulDiv(twapPrice, 7500, 10_000),
            "and spot is past the crash threshold"
        );

        assertLt(memeLens.liquidationHealthFactor(tokenId), 1e18, "a view reads under water");
        assertTrue(_liquidates(), "and the gate lets it through");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev Whether `liquidate` goes through, on a snapshot so the caller's state is untouched.
    ///      Any refusal other than `PositionIsHealthy` fails the test rather than reading as "no".
    function _liquidates() private returns (bool went) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(liquidator);
        try memeMarket.liquidate(tokenId, type(uint256).max, 0, 0, liquidator) {
            went = true;
        } catch (bytes memory reason) {
            assertEq(
                bytes32(bytes4(reason)),
                bytes32(MarketLiquidation.PositionIsHealthy.selector),
                "the only refusal is a healthy position"
            );
        }
        vm.revertToState(snapshot);
    }

    /// @dev One second past `staleThreshold` with nobody recording. The Chainlink feed is well
    ///      inside its 25 hours, so the recorder is the only thing that went stale.
    function _goStale() private {
        vm.warp(block.timestamp + STALE_AFTER + 1);
    }

    /// @dev Sells native ETH into the pool until spot is `bps` of where it stood. The price limit
    ///      stops the swap; the router hands back the ETH it did not need.
    function _sellEthUntilSpotIs(
        uint256 bps
    ) private {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        // sqrt(bps / 10_000), in the same fixed point as the price it scales.
        uint160 limit = uint160(FullMath.mulDiv(sqrtPriceX96, Math.sqrt(bps * 1e14), 1e9));

        PoolSwapTest router = new PoolSwapTest(poolManager);
        vm.deal(address(this), 1_000_000 ether);
        router.swap{value: 1_000_000 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1_000_000 ether), sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The swap router refunds unspent ETH to its caller.
    receive() external payable {}

    /// @dev A keeper's five-minute beat for `duration` seconds: the history §5.3 asks of a meme
    ///      pool before its first borrow.
    function _observeFor(
        uint256 duration
    ) private {
        recorder.record(key);
        for (uint256 elapsed = 0; elapsed < duration; elapsed += 300) {
            vm.warp(block.timestamp + 300);
            recorder.record(key);
        }
        usdgFeed.setAnswer(1e8, block.timestamp);
    }

    /// @dev Lets interest bring the health factor down, a day at a time with the keeper still
    ///      recording, so the recorder ends fresh. The lens reads the borrow price, which equals
    ///      the liquidation price while the pool stands still and the TWAP is fresh.
    function _ageUntilHealthFactorBelow(
        uint256 target
    ) private {
        for (uint256 i = 0; i < 4000; ++i) {
            if (memeLens.healthFactor(tokenId) < target) return;
            vm.warp(block.timestamp + 1 days);
            usdgFeed.setAnswer(1e8, block.timestamp);
            recorder.record(key);
            memeMarket.accrue();
        }
        revert("the health factor never fell far enough");
    }

    function _listAsMeme() private {
        TierPresets.Preset memory preset = TierPresets.meme();
        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: preset.minPositionUsd
            })
        );
    }

    /// @dev `_deployMarket` with the real oracle and its valuer in place of the base's mock.
    function _deployMemeMarket() private returns (FarmentaMarket) {
        FarmentaMarket implementation =
            new FarmentaMarket(positionManager, policy, memeValuer, memeOracle, interestRateModel);
        return FarmentaMarket(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            FarmentaMarket.initialize,
                            (IERC20(RobinhoodChain.USDG), "Farmenta USDG", "fUSDG", ICollateralPolicy.Tier.MEME, owner)
                        )
                    )
                ))
        );
    }
}
