// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice Runs the listing gate against real pool keys read from the chain.
/// @dev The unit tests build keys by hand and can only be as right as my assumptions. These
///      take the keys Uniswap actually stores — native ETH as currency0, a live hook, a
///      dynamic fee — so a key shaped differently from what I imagined shows up here.
contract CollateralPolicyForkTest is ForkTest {
    address internal owner = address(0xA11CE);
    CollateralPolicy internal policy;

    function setUp() public override {
        super.setUp();
        policy = new CollateralPolicy(Currency.wrap(RobinhoodChain.USDG), owner);

        vm.startPrank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.USDG), true, ICollateralPolicy.Tier.BLUE_CHIP, 6);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.WETH), true, ICollateralPolicy.Tier.BLUE_CHIP, 18);
        // Native ETH is address(0) inside a PoolKey, and two of the three fixture pools use
        // it as currency0. A policy that only handled ERC-20s would reject most of the
        // chain's ETH liquidity.
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.BLUE_CHIP, 18);
        vm.stopPrank();
    }

    /// @notice The largest ETH/USDG pool: native ETH, a live hook, and a dynamic fee.
    /// @dev Its hook is swap-only, so it needs no allowlisting — but since v0.5 that is not
    ///      admission either. The pool still has to be listed.
    function test_realDynFeePoolPassesOnceListed() public {
        PoolKey memory key = _keyOf(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        assertEq(Currency.unwrap(key.currency0), RobinhoodChain.NATIVE, "expected native ETH as currency0");
        assertEq(address(key.hooks), Fixtures.HOOK_ETH_USDG_DYN, "expected the dyn-fee hook");

        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolNotListed.selector, key.toId()));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);

        _list(key);

        ICollateralPolicy.Terms memory terms = policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
        assertEq(terms.maxLtvBps, 6500);
        assertEq(terms.ltBps, 7500);
        assertEq(uint8(terms.tier), uint8(ICollateralPolicy.Tier.BLUE_CHIP));
    }

    function test_realHooklessEthPoolPasses() public {
        PoolKey memory key = _keyOf(Fixtures.POS_ETH_USDG_ABOVE_RANGE);
        assertEq(address(key.hooks), address(0), "expected no hook");
        _list(key);
        assertTrue(policy.acceptsNewPositions(key.toId()));
    }

    /// @dev Both sides ERC-20 here, unlike the native-ETH pools above.
    function test_realWethPoolPasses() public {
        PoolKey memory key = _keyOf(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);
        assertEq(Currency.unwrap(key.currency0), RobinhoodChain.WETH);
        _list(key);
        assertTrue(policy.acceptsNewPositions(key.toId()));
    }

    /// @dev Every fixture pool quotes in USDG, which is what §1 restricts the MVP to. If a
    ///      pool were listed whose quote side was not USDG, the debt asset and the collateral
    ///      would be denominated differently and every LTV would be meaningless.
    function test_allFixturePoolsQuoteInUsdg() public view {
        PoolKey memory a = _keyOf(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        PoolKey memory b = _keyOf(Fixtures.POS_ETH_USDG_ABOVE_RANGE);
        PoolKey memory c = _keyOf(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);
        assertEq(Currency.unwrap(a.currency1), RobinhoodChain.USDG);
        assertEq(Currency.unwrap(b.currency1), RobinhoodChain.USDG);
        assertEq(Currency.unwrap(c.currency1), RobinhoodChain.USDG);
    }

    /// @dev Disabling native ETH after a pool was listed must stop new positions. Two of the
    ///      three fixture pools would be affected, which is the point of re-checking tokens
    ///      at deposit time rather than only at listing.
    function test_disablingNativeEthStopsItsPools() public {
        PoolKey memory key = _keyOf(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        _list(key);

        vm.prank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), false, ICollateralPolicy.Tier.BLUE_CHIP, 18);

        vm.expectRevert(
            abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, Currency.wrap(RobinhoodChain.NATIVE))
        );
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    function _keyOf(
        uint256 tokenId
    ) internal view returns (PoolKey memory key) {
        (key,) = positionManager.getPoolAndPositionInfo(tokenId);
    }

    function _list(
        PoolKey memory key
    ) internal {
        TierPresets.Preset memory preset = TierPresets.blueChip();
        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsd: preset.maxDebtCapUsd,
                minPositionUsd: preset.minPositionUsd
            })
        );
    }
}
