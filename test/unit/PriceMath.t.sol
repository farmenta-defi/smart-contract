// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PriceMath} from "../../src/libraries/PriceMath.sol";

/// @notice Unit tests for oracle-price → sqrt-price conversion. No network.
contract PriceMathTest is Test {
    uint8 internal constant ETH_DECIMALS = 18;
    uint8 internal constant USDG_DECIMALS = 6;

    uint256 internal constant ONE_USD = 1e18;

    PriceMathHarness internal harness;

    function setUp() public {
        harness = new PriceMathHarness();
    }

    /* ------------------------------ ground truth ------------------------------ */

    /// @notice Cross-checks the conversion against a real pool.
    /// @dev The ETH/USDG fixture pool sits at tick -198,000 at the pinned fork block, whose
    ///      exact sqrt price is 3977215967600538944242426. Ticks are one basis point apart, so
    ///      that tick spans ETH prices $2,519.9921 to $2,520.2441; $2,520.1181 is its midpoint
    ///      and must convert back onto the same tick. This checks the whole conversion —
    ///      decimals asymmetry included — against reality rather than against itself.
    function test_matchesTheRealPoolTick() public pure {
        uint160 derived = PriceMath.derivedSqrtPriceX96(2520.1181e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);

        assertEq(TickMath.getTickAtSqrtPrice(derived), -198_000, "derived price is not at the pool's tick");
        assertApproxEqRel(
            uint256(derived), 3_977_215_967_600_538_944_242_426, 0.0001e18, "sqrt price drifted from the pool's"
        );
    }

    /// @dev USDG has 6 decimals and ETH 18. If that asymmetry were dropped, the derived price
    ///      would be off by 1e12 — a position would be valued as entirely one-sided and the
    ///      error would look like a range problem, not a decimals problem.
    function test_decimalsAsymmetryIsLoadBearing() public pure {
        uint160 correct = PriceMath.derivedSqrtPriceX96(2519.9e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        uint160 asIf18 = PriceMath.derivedSqrtPriceX96(2519.9e18, ONE_USD, ETH_DECIMALS, ETH_DECIMALS);

        // sqrt(1e12) = 1e6 apart.
        assertApproxEqRel(uint256(asIf18), uint256(correct) * 1e6, 0.0001e18, "decimals are not being applied");
    }

    /* --------------------------------- guards --------------------------------- */

    /// @dev Reverts are exercised through `harness` because library `internal` functions are
    ///      inlined into the caller, and `vm.expectRevert` needs the revert to happen one call
    ///      frame deeper than the cheatcode.
    function test_zeroPriceReverts() public {
        vm.expectRevert(PriceMath.ZeroPrice.selector);
        harness.derivedSqrtPriceX96(0, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);

        vm.expectRevert(PriceMath.ZeroPrice.selector);
        harness.derivedSqrtPriceX96(ONE_USD, 0, ETH_DECIMALS, USDG_DECIMALS);
    }

    /// @dev A price ratio Uniswap cannot represent must revert rather than silently clamp:
    ///      a clamped price would value every position as fully one-sided.
    function test_priceBelowUniswapRangeReverts() public {
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        harness.derivedSqrtPriceX96(1, 1e40, 18, 18);
    }

    /// @dev The upper end reverts too, but inside `FullMath.mulDiv` rather than with our own
    ///      error. Uniswap's maximum representable price is ~2**128, which is exactly where
    ///      `ratio << 128` stops fitting in 256 bits — so the overflow guard fires first and
    ///      leaves almost no gap for `PriceOutOfRange` to catch. Asserted as "reverts" rather
    ///      than pretending we control which error surfaces.
    function test_priceAboveUniswapRangeReverts() public {
        vm.expectRevert();
        harness.derivedSqrtPriceX96(1e40, 1, 18, 18);
    }

    /* ------------------------------- properties ------------------------------- */

    function testFuzz_risesWithCurrency0Price(
        uint256 price0,
        uint256 bump
    ) public pure {
        price0 = bound(price0, 1e12, 1e30);
        bump = bound(bump, 1e12, 1e30);

        uint160 low = PriceMath.derivedSqrtPriceX96(price0, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        uint160 high = PriceMath.derivedSqrtPriceX96(price0 + bump, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        assertGe(high, low, "a more valuable currency0 must not lower the price");
    }

    function testFuzz_fallsWithCurrency1Price(
        uint256 price1,
        uint256 bump
    ) public pure {
        price1 = bound(price1, 1e12, 1e24);
        bump = bound(bump, 1e12, 1e24);

        uint160 high = PriceMath.derivedSqrtPriceX96(1000e18, price1, ETH_DECIMALS, USDG_DECIMALS);
        uint160 low = PriceMath.derivedSqrtPriceX96(1000e18, price1 + bump, ETH_DECIMALS, USDG_DECIMALS);
        assertLe(low, high, "a more valuable currency1 must not raise the price");
    }

    /* ---------------------------- spot deviation ------------------------------ */

    function test_noDeviationWhenSpotMatchesOracle() public pure {
        uint160 derived = PriceMath.derivedSqrtPriceX96(2519.9e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        assertEq(PriceMath.spotDeviationBps(derived, derived), 0);
    }

    /// @dev The ±2% borrow gate in §5.2 is defined on price. Deviation is therefore measured
    ///      on price too: a 2% price gap is only ~1% in sqrt space, so comparing roots would
    ///      let roughly twice the intended drift through.
    function test_twoPercentPriceGapReadsAsTwoHundredBps() public pure {
        uint160 derived = PriceMath.derivedSqrtPriceX96(2500e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        uint160 spotUp = PriceMath.derivedSqrtPriceX96(2550e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        uint160 spotDown = PriceMath.derivedSqrtPriceX96(2450e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);

        assertApproxEqAbs(PriceMath.spotDeviationBps(spotUp, derived), 200, 1, "upward 2% misread");
        assertApproxEqAbs(PriceMath.spotDeviationBps(spotDown, derived), 200, 1, "downward 2% misread");
    }

    function testFuzz_deviationIsNeverNegativeAndZeroOnlyWhenEqual(
        uint256 spotPrice
    ) public pure {
        spotPrice = bound(spotPrice, 1e15, 1e28);
        uint160 derived = PriceMath.derivedSqrtPriceX96(2500e18, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);
        uint160 spot = PriceMath.derivedSqrtPriceX96(spotPrice, ONE_USD, ETH_DECIMALS, USDG_DECIMALS);

        uint256 deviation = PriceMath.spotDeviationBps(spot, derived);
        if (spot == derived) assertEq(deviation, 0);
    }
}

/// @notice Exposes the library externally so reverts land one frame below `vm.expectRevert`.
contract PriceMathHarness {
    function derivedSqrtPriceX96(
        uint256 price0,
        uint256 price1,
        uint8 decimals0,
        uint8 decimals1
    ) external pure returns (uint160) {
        return PriceMath.derivedSqrtPriceX96(price0, price1, decimals0, decimals1);
    }

    function spotDeviationBps(
        uint160 sqrtSpotX96,
        uint160 sqrtDerivedX96
    ) external pure returns (uint256) {
        return PriceMath.spotDeviationBps(sqrtSpotX96, sqrtDerivedX96);
    }
}
