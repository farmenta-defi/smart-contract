// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {PositionAmounts} from "../../src/libraries/PositionAmounts.sol";

/// @notice Unit tests for position math. No network — this is the fast CI lane.
contract PositionAmountsTest is Test {
    int24 internal constant LOWER = -198_000;
    int24 internal constant UPPER = -196_000;
    uint128 internal constant LIQUIDITY = 1e15;

    uint160 internal sqrtLower;
    uint160 internal sqrtUpper;

    function setUp() public {
        sqrtLower = TickMath.getSqrtPriceAtTick(LOWER);
        sqrtUpper = TickMath.getSqrtPriceAtTick(UPPER);
    }

    /* ------------------------------- range sides ------------------------------ */

    function test_belowRangeIsAllCurrency0() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(LOWER - 1000);
        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, LIQUIDITY);
        assertGt(amount0, 0, "should hold currency0");
        assertEq(amount1, 0, "should hold no currency1");
    }

    function test_aboveRangeIsAllCurrency1() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(UPPER + 1000);
        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, LIQUIDITY);
        assertEq(amount0, 0, "should hold no currency0");
        assertGt(amount1, 0, "should hold currency1");
    }

    function test_inRangeHoldsBoth() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick((LOWER + UPPER) / 2);
        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, LIQUIDITY);
        assertGt(amount0, 0, "should hold currency0");
        assertGt(amount1, 0, "should hold currency1");
    }

    /// @dev The boundaries are the seam between the three branches. At exactly `sqrtLower`
    ///      the position is entirely currency0; at exactly `sqrtUpper`, entirely currency1.
    function test_boundariesResolveToTheOneSidedBranches() public view {
        (uint256 a0, uint256 a1) = PositionAmounts.forLiquidity(sqrtLower, sqrtLower, sqrtUpper, LIQUIDITY);
        assertGt(a0, 0);
        assertEq(a1, 0, "at the lower bound the position is all currency0");

        (uint256 b0, uint256 b1) = PositionAmounts.forLiquidity(sqrtUpper, sqrtLower, sqrtUpper, LIQUIDITY);
        assertEq(b0, 0, "at the upper bound the position is all currency1");
        assertGt(b1, 0);
    }

    function test_boundsMayArriveReversed() public view {
        (uint256 a0, uint256 a1) = PositionAmounts.forLiquidity(sqrtLower, sqrtLower, sqrtUpper, LIQUIDITY);
        (uint256 b0, uint256 b1) = PositionAmounts.forLiquidity(sqrtLower, sqrtUpper, sqrtLower, LIQUIDITY);
        assertEq(a0, b0, "swapped bounds changed amount0");
        assertEq(a1, b1, "swapped bounds changed amount1");
    }

    function test_zeroLiquidityHoldsNothing() public view {
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick((LOWER + UPPER) / 2);
        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, 0);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    /* -------------------------- cross-check vs Uniswap ------------------------- */

    /// @notice Round-trips through Uniswap's own inverse function.
    /// @dev `getAmountsForLiquidity` ships only under `v4-core/test/utils` (UNLICENSED), so
    ///      `PositionAmounts.forLiquidity` is our own implementation. Uniswap's MIT-licensed
    ///      `getLiquidityForAmounts` runs the conversion the other way, which gives an
    ///      independent check of ours.
    ///
    ///      The round trip is asserted on **amounts**, not on liquidity. Liquidity recovered
    ///      from floored amounts can differ by a lot in absolute terms — one dropped wei of
    ///      amount converts back into sqrtP*sqrtB/(Q96*(sqrtB-sqrtP)) units of liquidity,
    ///      which diverges as the price approaches a range boundary. The amounts themselves
    ///      are what value a position, and they are stable to a couple of wei.
    function testFuzz_roundTripAgainstUniswapInverse(
        uint128 liquidity,
        int24 tick
    ) public view {
        liquidity = uint128(bound(liquidity, 1e6, type(uint96).max));
        tick = int24(bound(tick, LOWER - 5000, UPPER + 5000));
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);

        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, liquidity);
        uint128 recovered = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice, sqrtLower, sqrtUpper, amount0, amount1);

        // The property that protects lenders: rounding is down, so a round trip can only
        // lose. Gaining would mean a position could be valued above what it can return.
        assertLe(recovered, liquidity, "round-trip gained liquidity - rounding is not down");

        // Re-deriving amounts from the recovered liquidity lands back where we started, and
        // never above: `getLiquidityForAmounts` takes min(L0, L1), so when the two sides
        // disagree the recovered liquidity is the conservative one.
        (uint256 back0, uint256 back1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, recovered);
        assertLe(back0, amount0, "round trip inflated amount0");
        assertLe(back1, amount1, "round trip inflated amount1");
        // Closeness is only claimed where there is precision to claim. A side holding a
        // handful of wei quantises hard, and `getLiquidityForAmounts` takes min(L0, L1), so
        // that side then dictates the result — see `test_aDustSideQuantisesHard`. Farmenta
        // keeps such positions out of the protocol entirely via minPositionValue ($50, §6.2).
        if (amount0 + amount1 < 1e6) return; // the whole position is dust
        bool inRange = sqrtPrice > sqrtLower && sqrtPrice < sqrtUpper;
        // In range both sides feed min(L0, L1), so either one being dust decides the result.
        // Out of range one side is legitimately zero and only the other carries the value.
        if (inRange && (amount0 < 1e6 || amount1 < 1e6)) return;

        // Slack is absolute *and* relative: small amounts lose whole wei to flooring, large
        // ones lose a proportional trickle. Neither regime is covered by the other alone.
        // The bound exists to catch an implementation being wrong, which would show up
        // orders of magnitude larger — not to claim a precision we do not have.
        assertLe(amount0 - back0, 4 + amount0 / 1e4, "amount0 drifted beyond rounding");
        assertLe(amount1 - back1, 4 + amount1 / 1e4, "amount1 drifted beyond rounding");
    }

    /// @notice Documents the precision floor: a position holding wei-scale amounts on one
    ///         side cannot be round-tripped accurately, and that is inherent, not a bug.
    /// @dev With liquidity 1,000,001 in this range the position holds 902,332,729 of
    ///      currency0 but only **2 wei** of currency1. Flooring 2.6 wei to 2 throws away 23%
    ///      of that side, and since `getLiquidityForAmounts` returns min(L0, L1), the
    ///      degraded side decides: 759,193 comes back instead of 1,000,001.
    ///
    ///      This is why §6.2 sets a $50 minimum position value. Valuation stays sound because
    ///      rounding is down — the position is undervalued, never over — but a dust position
    ///      is not something to lend against.
    function test_aDustSideQuantisesHard() public view {
        uint128 liquidity = 1_000_001;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(-196_977);

        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, liquidity);
        assertEq(amount0, 902_332_729, "currency0 amount moved");
        assertEq(amount1, 2, "currency1 should be dust here");

        uint128 recovered = LiquidityAmounts.getLiquidityForAmounts(sqrtPrice, sqrtLower, sqrtUpper, amount0, amount1);
        assertEq(recovered, 759_193, "quantisation loss moved");
        assertLt(recovered, liquidity, "recovery must never exceed the original");
    }

    /// @dev Value must be monotonic in liquidity: doubling a position never shrinks it.
    ///      A borrower's collateral value is derived from this, so a non-monotonic result
    ///      would be exploitable.
    function testFuzz_monotonicInLiquidity(
        uint128 liquidity,
        int24 tick
    ) public view {
        liquidity = uint128(bound(liquidity, 1e6, type(uint96).max));
        tick = int24(bound(tick, LOWER - 5000, UPPER + 5000));
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(tick);

        (uint256 a0, uint256 a1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, liquidity);
        (uint256 b0, uint256 b1) = PositionAmounts.forLiquidity(sqrtPrice, sqrtLower, sqrtUpper, liquidity * 2);
        assertGe(b0, a0, "amount0 shrank when liquidity grew");
        assertGe(b1, a1, "amount1 shrank when liquidity grew");
    }

    /* ---------------------------------- fees ---------------------------------- */

    function test_feesAreGrowthDeltaTimesLiquidity() public pure {
        // One full Q128 of growth over 1e18 liquidity is exactly 1e18 of fees.
        (uint256 fees0, uint256 fees1) = PositionAmounts.feesOwed(PositionAmounts.Q128, 0, 0, 0, 1e18);
        assertEq(fees0, 1e18);
        assertEq(fees1, 0);
    }

    function test_noGrowthMeansNoFees() public pure {
        (uint256 fees0, uint256 fees1) = PositionAmounts.feesOwed(12_345, 67_890, 12_345, 67_890, 1e18);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }

    /// @dev Fee-growth counters are unbounded and wrap by design; the subtraction must wrap
    ///      with them. If this were checked arithmetic, a position whose cached growth sits
    ///      just below 2**256 would revert on every valuation — bricking both borrowing and
    ///      liquidation for it.
    function test_growthCounterWrapIsHandled() public pure {
        uint256 last = type(uint256).max - (PositionAmounts.Q128 / 2);
        uint256 current = PositionAmounts.Q128 / 2; // wrapped past the top by one Q128
        (uint256 fees0,) = PositionAmounts.feesOwed(current, 0, last, 0, 1e18);
        assertEq(fees0, 1e18, "wrapped growth did not yield one Q128 of fees");
    }

    function testFuzz_feesScaleWithLiquidity(
        uint128 liquidity,
        uint128 growthDelta
    ) public pure {
        liquidity = uint128(bound(liquidity, 0, type(uint96).max));
        (uint256 fees0,) = PositionAmounts.feesOwed(growthDelta, 0, 0, 0, liquidity);
        (uint256 doubled,) = PositionAmounts.feesOwed(growthDelta, 0, 0, 0, liquidity == 0 ? 0 : liquidity * 2);
        assertGe(doubled, fees0, "fees shrank when liquidity grew");
    }
}
