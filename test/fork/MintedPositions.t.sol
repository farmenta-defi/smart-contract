// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PositionValuer} from "../../src/PositionValuer.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {PositionMinter} from "../base/PositionMinter.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice Values position shapes the chain does not happen to hold.
/// @dev The real fixtures cover ordinary positions. These cover the edges: a single-tick
///      range, wei-scale liquidity, and a position genuinely below the current price — the
///      last of which cannot be taken from the chain, because LPs close such positions
///      rather than hold a fully one-sided bag.
contract MintedPositionsForkTest is PositionMinter {
    uint256 internal constant ETH_AT_POOL_SPOT = 2520.1324440246868e18;
    uint256 internal constant ONE_USD = 1e18;

    MockPriceOracle internal oracle;
    PositionValuer internal valuer;

    PoolKey internal key;
    int24 internal spacing;

    /// @dev The tick the **oracle** implies, not the pool's. Ranges are placed relative to
    ///      this because the valuer decides in/out of range at the oracle price; the pool's
    ///      own tick never enters that decision (§5.1).
    int24 internal oracleTick;

    function setUp() public override {
        super.setUp();

        oracle = new MockPriceOracle();
        oracle.set(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), ONE_USD, RobinhoodChain.USDG_DECIMALS);
        valuer = new PositionValuer(positionManager, stateView, oracle);

        // Borrow the WETH/USDG pool's key from a real position rather than reconstructing it:
        // a PoolKey built by hand that differs in any field addresses a different pool.
        (key,) = positionManager.getPoolAndPositionInfo(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);
        spacing = key.tickSpacing;

        oracleTick = TickMath.getTickAtSqrtPrice(
            PriceMath.derivedSqrtPriceX96(ETH_AT_POOL_SPOT, ONE_USD, 18, RobinhoodChain.USDG_DECIMALS)
        );
    }

    /// @notice A position one tick wide — the tightest range Uniswap allows.
    function test_singleTickRangeValues() public {
        int24 lower = _align(oracleTick);
        _fundAndApprove(key, 10 ether, 100_000e6);
        uint256 tokenId = _mint(key, lower, lower + spacing, 1e15);

        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertEq(v.liquidity, 1e15, "minted liquidity not reflected");
        assertGt(v.principalUsd, 0, "single-tick position must hold value");
        assertEq(v.feesUsd, 0, "a freshly minted position has earned nothing");
    }

    /// @notice Price below the range: the position is 100% of the risky token.
    /// @dev This is the shape that makes a blue-chip loan liquidatable (§6.4) — value tracks
    ///      WETH alone and falls with it. No real position on this chain is in this state, so
    ///      it can only be reached by minting one.
    ///
    ///      Note the direction: "below the range" means the *price* is below it, so the range
    ///      is minted **above** the current tick. Getting this backwards silently produces the
    ///      opposite, all-USDG position — which is the safe case, not the dangerous one.
    function test_belowRangePositionIsAllRiskyToken() public {
        int24 lower = _align(oracleTick + 10 * spacing);
        _fundAndApprove(key, 10 ether, 100_000e6);
        uint256 tokenId = _mint(key, lower, lower + 10 * spacing, 1e15);

        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertEq(v.amount1, 0, "below range there is no USDG left");
        assertGt(v.amount0, 0, "below range the position is all WETH");
        assertEq(v.principalUsd, _wethUsd(v.amount0), "value must be exactly the WETH it holds");
    }

    /// @notice Mirror image: price above the range, so the position is 100% USDG.
    /// @dev §6.4's safe direction — the health factor only improves and no action is taken.
    ///      The range is minted **below** the current tick.
    function test_aboveRangePositionIsAllUsdg() public {
        int24 upper = _align(oracleTick - 10 * spacing);
        _fundAndApprove(key, 10 ether, 100_000e6);
        uint256 tokenId = _mint(key, upper - 10 * spacing, upper, 1e15);

        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertEq(v.amount0, 0, "above range there is no WETH left");
        assertGt(v.amount1, 0, "above range the position is all USDG");
        assertEq(v.principalUsd, v.amount1 * 1e12, "USDG value must scale 6 decimals to 18");
    }

    /// @notice Wei-scale liquidity values without reverting, and stays worth almost nothing.
    /// @dev Rounding is down, so a dust position is undervalued rather than over — safe, but
    ///      worthless as collateral, which is what minPositionValue ($50, §6.2) enforces.
    function test_dustLiquidityValuesToNearlyNothing() public {
        int24 lower = _align(oracleTick);
        _fundAndApprove(key, 10 ether, 100_000e6);
        uint256 tokenId = _mint(key, lower - 10 * spacing, lower + 10 * spacing, 1);

        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertEq(v.liquidity, 1, "dust liquidity not reflected");
        assertLt(v.principalUsd, 1e18, "one unit of liquidity cannot be worth a dollar");
    }

    /// @notice Minting does not disturb the real fixtures the other tests rely on.
    function test_mintingLeavesTheRealFixturesAlone() public {
        IPositionValuer.Valuation memory before = valuer.value(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);

        _fundAndApprove(key, 10 ether, 100_000e6);
        _mint(key, _align(oracleTick) - 10 * spacing, _align(oracleTick) + 10 * spacing, 1e15);

        IPositionValuer.Valuation memory afterMint = valuer.value(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);
        assertEq(afterMint.liquidity, before.liquidity, "a fixture's liquidity moved");
        assertEq(afterMint.principalUsd, before.principalUsd, "a fixture's value moved");
    }

    /// @dev Ticks must sit on the pool's spacing; Solidity truncates toward zero, so negative
    ///      ticks need the extra step to floor rather than round up.
    function _align(
        int24 tick
    ) internal view returns (int24) {
        // Dividing before multiplying is the point here: it snaps the tick down to a
        // multiple of the spacing. Precision "loss" is the rounding we want.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
        return aligned;
    }

    function _wethUsd(
        uint256 amount
    ) internal pure returns (uint256) {
        return (amount * ETH_AT_POOL_SPOT) / 1e18;
    }
}
