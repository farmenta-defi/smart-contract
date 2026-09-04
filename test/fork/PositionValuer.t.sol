// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PositionValuer} from "../../src/PositionValuer.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice Values real positions, with prices under the test's control.
/// @dev The pool is real and frozen at the pinned block; only the oracle moves. That
///      separation is the point: it shows valuation tracks the oracle rather than the pool.
contract PositionValuerForkTest is ForkTest {
    /// @dev ETH price implied by the ETH/USDG dyn-fee pool's own spot price at the pinned
    ///      block (sqrtPriceX96 3977326707449570204479991), with USDG at $1. Setting the
    ///      oracle here makes the derived price and the pool's price agree.
    uint256 internal constant ETH_AT_POOL_SPOT = 2520.1324440246868e18;
    uint256 internal constant ONE_USD = 1e18;

    /// @dev Reference amounts for POS_ETH_USDG_DYN computed at the pool's spot price.
    uint256 internal constant REF_AMOUNT0 = 22_640_826_955_825_859;
    uint256 internal constant REF_AMOUNT1 = 325_947_874;

    MockPriceOracle internal oracle;
    PositionValuer internal valuer;

    function setUp() public override {
        super.setUp();
        oracle = new MockPriceOracle();
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), ONE_USD, RobinhoodChain.USDG_DECIMALS);
        valuer = new PositionValuer(positionManager, stateView, oracle);
    }

    /// @notice With the oracle set to the pool's own price, valuation reproduces what the
    ///         pool itself would return — and reports no drift.
    function test_matchesThePoolWhenTheOracleAgreesWithIt() public view {
        IPositionValuer.Valuation memory v = valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);

        assertApproxEqRel(v.amount0, REF_AMOUNT0, 0.0001e18, "currency0 amount drifted from the pool's");
        assertApproxEqRel(v.amount1, REF_AMOUNT1, 0.0001e18, "currency1 amount drifted from the pool's");
        assertLt(v.spotDeviationBps, 2, "oracle and pool should agree here");
    }

    /// @notice The property the whole design rests on: what a position is worth follows the
    ///         oracle, not the pool.
    /// @dev The fork is pinned, so the pool is bit-for-bit identical across both calls. Only
    ///      the oracle moves. A cheaper currency0 means the position holds more of it and
    ///      less currency1 — and the reported drift grows to match, which is what feeds the
    ///      ±2% borrow gate in §5.2.
    function test_valuationFollowsTheOracleWhileThePoolStandsStill() public {
        IPositionValuer.Valuation memory before = valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);

        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT / 2, 18);
        IPositionValuer.Valuation memory afterDrop = valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);

        assertGt(afterDrop.amount0, before.amount0, "a cheaper currency0 must leave more of it");
        assertLt(afterDrop.amount1, before.amount1, "a cheaper currency0 must leave less currency1");
        assertLt(afterDrop.principalUsd, before.principalUsd, "halving the price must lower the value");
        assertGt(afterDrop.spotDeviationBps, 4000, "a 50% gap must be reported as large drift");
    }

    /// @notice Moving the oracle across the position's range makes it one-sided, on a real
    ///         position — no minting required.
    /// @dev POS_ETH_USDG_DYN spans roughly $2,366 to $2,548 of ETH. Below that band the
    ///      position is entirely ETH, which is exactly the shape that makes a blue-chip loan
    ///      liquidatable (§6.4); above it, entirely USDG, which is the safe direction.
    function test_oraclePriceCrossingTheRangeMakesThePositionOneSided() public {
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2000e18, 18);
        IPositionValuer.Valuation memory below = valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        assertGt(below.amount0, 0, "below the range the position is all currency0");
        assertEq(below.amount1, 0, "below the range there is no currency1 left");

        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 3000e18, 18);
        IPositionValuer.Valuation memory above = valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        assertEq(above.amount0, 0, "above the range there is no currency0 left");
        assertGt(above.amount1, 0, "above the range the position is all currency1");
    }

    /// @notice USD conversion respects each token's decimals.
    /// @dev The above-range fixture holds only USDG, so at $1 its USD value must equal its
    ///      raw amount scaled from 6 decimals to 18 — exactly, with no rounding to hide
    ///      behind. Getting this wrong by 1e12 is the classic decimals bug.
    function test_usdValueRespectsDecimals() public view {
        IPositionValuer.Valuation memory v = valuer.value(Fixtures.POS_ETH_USDG_ABOVE_RANGE);

        assertEq(v.amount0, 0, "fixture should be above its range");
        assertEq(v.principalUsd, v.amount1 * 1e12, "USDG value must scale 6 decimals to 18");
        assertEq(v.feesUsd, 0, "fixture has freshly collected fees");
    }

    /// @notice Fees are reported separately from principal, and uncapped.
    /// @dev The market applies the 10%-of-principal cap from §6.2; the valuer must not, or a
    ///      change to that parameter would mean deploying a new valuer.
    function test_feesAreReportedSeparatelyAndUncapped() public view {
        IPositionValuer.Valuation memory v = valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);

        assertGt(v.fees0, 0, "fixture has uncollected currency0 fees");
        assertGt(v.fees1, 0, "fixture has uncollected currency1 fees");
        assertGt(v.feesUsd, 0, "fees should carry USD value");
        // ~$11 of fees on a ~$382 position at the pinned block.
        assertApproxEqRel(v.feesUsd, 11.3e18, 0.05e18, "fee value moved");
        assertApproxEqRel(v.principalUsd, 382e18, 0.05e18, "principal value moved");
    }

    function test_bothErc20SidesValueCorrectly() public view {
        IPositionValuer.Valuation memory v = valuer.value(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);

        assertGt(v.amount0, 0, "wide in-range position holds WETH");
        assertGt(v.amount1, 0, "wide in-range position holds USDG");
        assertGt(v.principalUsd, 0);
    }

    function test_unknownPositionReverts() public {
        uint256 missing = positionManager.nextTokenId() + 1;
        vm.expectRevert(abi.encodeWithSelector(IPositionValuer.PositionNotFound.selector, missing));
        valuer.value(missing);
    }

    /// @dev An unpriced currency must stop valuation rather than value it at zero, which
    ///      would silently report a position as worthless and make it instantly liquidatable.
    function test_missingPriceStopsValuation() public {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        oracle.set(key.currency0, 0, 18);

        vm.expectRevert(abi.encodeWithSelector(MockPriceOracle.PriceNotSet.selector, key.currency0));
        valuer.value(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
    }
}
