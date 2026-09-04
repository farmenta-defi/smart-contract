// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {PositionAmounts} from "../../src/libraries/PositionAmounts.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice Guards the real positions used as fixtures against drifting out from under us.
/// @dev These belong to strangers who can close them at any time. The fork is pinned, so
///      they cannot actually change — but the pin can be raised, and then a fixture that
///      quietly became empty would weaken every test built on it without failing anything.
///      These assertions make that loud.
contract PositionFixturesForkTest is ForkTest {
    using PositionInfoLibrary for PositionInfo;

    struct Shape {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address currency0;
        address hooks;
        bool inRange;
        bool hasFees;
    }

    function test_ethUsdgDynInRange() public view {
        _assertShape(
            Fixtures.POS_ETH_USDG_DYN_IN_RANGE,
            Shape({
                tickLower: -198_627,
                tickUpper: -197_891,
                liquidity: 210_198_945_969_578,
                currency0: RobinhoodChain.NATIVE,
                hooks: Fixtures.HOOK_ETH_USDG_DYN,
                inRange: true,
                hasFees: true
            })
        );
    }

    function test_ethUsdgInRange() public view {
        _assertShape(
            Fixtures.POS_ETH_USDG_IN_RANGE,
            Shape({
                tickLower: -198_018,
                tickUpper: -197_973,
                liquidity: 15_529_226_464_688_778,
                currency0: RobinhoodChain.NATIVE,
                hooks: address(0),
                inRange: true,
                hasFees: true
            })
        );
    }

    /// @dev Above range means 100% currency1 (USDG) — the safe direction in §6.4, where the
    ///      health factor only improves. Fees were collected, so the growth delta is zero.
    function test_ethUsdgAboveRangeWithNoFees() public view {
        (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) = _read(
            Fixtures.POS_ETH_USDG_ABOVE_RANGE,
            Shape({
                tickLower: -198_486,
                tickUpper: -198_036,
                liquidity: 2_202_228_439_131_196,
                currency0: RobinhoodChain.NATIVE,
                hooks: address(0),
                inRange: false,
                hasFees: false
            })
        );
        assertEq(amount0, 0, "above range must hold no currency0");
        assertGt(amount1, 0, "above range must hold currency1");
        assertEq(fees0, 0, "expected freshly collected fees");
        assertEq(fees1, 0, "expected freshly collected fees");
    }

    function test_wethUsdgWideInRange() public view {
        _assertShape(
            Fixtures.POS_WETH_USDG_WIDE_IN_RANGE,
            Shape({
                tickLower: -199_784,
                tickUpper: -196_288,
                liquidity: 717_683_748_349_902,
                currency0: RobinhoodChain.WETH,
                hooks: address(0),
                inRange: true,
                hasFees: true
            })
        );
    }

    function test_wethUsdgAboveRange() public view {
        (uint256 amount0, uint256 amount1,,) = _read(
            Fixtures.POS_WETH_USDG_ABOVE_RANGE,
            Shape({
                tickLower: -198_064,
                tickUpper: -197_992,
                liquidity: 49_873_503_705_365_010,
                currency0: RobinhoodChain.WETH,
                hooks: address(0),
                inRange: false,
                hasFees: true
            })
        );
        assertEq(amount0, 0, "above range must hold no currency0");
        assertGt(amount1, 0, "above range must hold currency1");
    }

    /// @dev Every fixture quotes into USDG. That is a §1 product decision (MVP takes only
    ///      pairs quoted in USDG), so it is asserted rather than assumed.
    function test_everyFixtureIsQuotedInUsdg() public view {
        uint256[5] memory ids = [
            Fixtures.POS_ETH_USDG_DYN_IN_RANGE,
            Fixtures.POS_ETH_USDG_IN_RANGE,
            Fixtures.POS_ETH_USDG_ABOVE_RANGE,
            Fixtures.POS_WETH_USDG_WIDE_IN_RANGE,
            Fixtures.POS_WETH_USDG_ABOVE_RANGE
        ];
        for (uint256 i; i < ids.length; ++i) {
            (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(ids[i]);
            assertEq(Currency.unwrap(key.currency1), RobinhoodChain.USDG, "currency1 is not USDG");
        }
    }

    function _assertShape(
        uint256 tokenId,
        Shape memory want
    ) internal view {
        _read(tokenId, want);
    }

    function _read(
        uint256 tokenId,
        Shape memory want
    ) internal view returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1) {
        PoolId poolId = _assertStatic(tokenId, want);
        (amount0, amount1) = _amounts(poolId, tokenId, want);
        (fees0, fees1) = _fees(poolId, tokenId, want);
        assertEq(fees0 > 0 || fees1 > 0, want.hasFees, "fee expectation moved");
    }

    /// @dev Everything that must match exactly: geometry, currencies, hook, liquidity.
    ///      Split out from `_read` to keep each frame under the stack limit.
    function _assertStatic(
        uint256 tokenId,
        Shape memory want
    ) internal view returns (PoolId poolId) {
        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        assertTrue(PositionInfo.unwrap(info) != 0, "fixture position no longer exists");

        assertEq(info.tickLower(), want.tickLower, "tickLower moved");
        assertEq(info.tickUpper(), want.tickUpper, "tickUpper moved");
        assertEq(Currency.unwrap(key.currency0), want.currency0, "currency0 moved");
        assertEq(address(key.hooks), want.hooks, "hook moved");

        poolId = key.toId();
        assertEq(positionManager.getPositionLiquidity(tokenId), want.liquidity, "liquidity moved");

        (, int24 tick,,) = stateView.getSlot0(poolId);
        assertEq(tick >= want.tickLower && tick < want.tickUpper, want.inRange, "range status moved");
    }

    function _amounts(
        PoolId poolId,
        uint256 tokenId,
        Shape memory want
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        (amount0, amount1) = PositionAmounts.forLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(want.tickLower),
            TickMath.getSqrtPriceAtTick(want.tickUpper),
            positionManager.getPositionLiquidity(tokenId)
        );
        assertTrue(amount0 > 0 || amount1 > 0, "position holds nothing");
    }

    function _fees(
        PoolId poolId,
        uint256 tokenId,
        Shape memory want
    ) internal view returns (uint256 fees0, uint256 fees1) {
        bytes32 positionKey =
            Position.calculatePositionKey(address(positionManager), want.tickLower, want.tickUpper, bytes32(tokenId));
        (uint128 liquidity, uint256 fg0Last, uint256 fg1Last) = stateView.getPositionInfo(poolId, positionKey);
        (uint256 fgIn0, uint256 fgIn1) = stateView.getFeeGrowthInside(poolId, want.tickLower, want.tickUpper);
        (fees0, fees1) = PositionAmounts.feesOwed(fgIn0, fgIn1, fg0Last, fg1Last, liquidity);
    }
}
