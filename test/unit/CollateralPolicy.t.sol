// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";

/// @notice Unit tests for listing, terms, and the LT ramp. No network.
contract CollateralPolicyTest is Test {
    Currency internal usdg = Currency.wrap(RobinhoodChain.USDG);
    Currency internal weth = Currency.wrap(RobinhoodChain.WETH);
    /// @dev Sorts above USDG, so meme pairs exercise the opposite currency ordering.
    Currency internal memeToken = Currency.wrap(address(0xBEeFbeefbEefbeEFbeEfbEEfBEeFbeEfBeEfBeef));

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBAD);

    CollateralPolicy internal policy;

    function setUp() public {
        policy = new CollateralPolicy(usdg, owner);

        vm.startPrank(owner);
        policy.setTokenConfig(usdg, true, ICollateralPolicy.Tier.BLUE_CHIP, 6);
        policy.setTokenConfig(weth, true, ICollateralPolicy.Tier.BLUE_CHIP, 18);
        policy.setTokenConfig(memeToken, true, ICollateralPolicy.Tier.MEME, 18);
        vm.stopPrank();
    }

    /* ----------------------------- access control ----------------------------- */

    /// @dev Every mutating entry point is owner-only. A permissionless path into any of these
    ///      would let a stranger list a pool of their own making and lend against it.
    function test_everyMutatingFunctionIsOwnerOnly() public {
        PoolKey memory key = _blueChipKey(address(0));
        CollateralPolicy.ListingParams memory p = _blueChipParams();

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.setTokenConfig(weth, true, ICollateralPolicy.Tier.BLUE_CHIP, 18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.setHookAllowlist(address(1), true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.list(key, p);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.updateTerms(key.toId(), p);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.setFrozen(key.toId(), true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.scheduleLtRamp(key.toId(), 1000, uint40(block.timestamp + 1), 1 days);
        vm.stopPrank();
    }

    /* --------------------------------- listing -------------------------------- */

    function test_listingStoresTheTermsAndDerivesTheTier() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());

        ICollateralPolicy.Terms memory terms = policy.termsOf(key.toId());
        assertEq(uint8(terms.tier), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier");
        assertEq(terms.maxLtvBps, 6500);
        assertEq(terms.ltBps, 7500);
        assertEq(terms.liquidatorBonusBps, 500);
        assertTrue(policy.acceptsNewPositions(key.toId()));
    }

    /// @dev The tier comes from the pool's tokens, not from the caller, so a meme pair cannot
    ///      be listed on blue-chip terms by mistake.
    function test_tierComesFromTheRiskierToken() public {
        PoolKey memory key = _memeKey(address(0));
        _list(key, _memeParams());
        assertEq(uint8(policy.termsOf(key.toId()).tier), uint8(ICollateralPolicy.Tier.MEME));
    }

    /// @dev Meme terms are checked against the meme preset even though USDG in the pair is
    ///      blue-chip. Taking the safer token's tier would lend 65% against a meme coin.
    function test_memePairCannotTakeBlueChipTerms() public {
        PoolKey memory key = _memeKey(address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.LooserThanPreset.selector, "maxLtv"));
        policy.list(key, _blueChipParams());
    }

    function test_cannotListTwice() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolAlreadyListed.selector, key.toId()));
        policy.list(key, _blueChipParams());
    }

    function test_unlistedPoolHasNoTerms() public {
        PoolId poolId = _blueChipKey(address(0)).toId();
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolNotListed.selector, poolId));
        policy.termsOf(poolId);
        assertFalse(policy.acceptsNewPositions(poolId));
    }

    function test_bothTokensMustBeEnabled() public {
        vm.prank(owner);
        policy.setTokenConfig(weth, false, ICollateralPolicy.Tier.BLUE_CHIP, 18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, weth));
        policy.list(_blueChipKey(address(0)), _blueChipParams());
    }

    /// @dev §1: the MVP only takes pairs quoted in USDG.
    function test_pairMustQuoteInUsdg() public {
        Currency other = Currency.wrap(address(0xCAFE));
        vm.prank(owner);
        policy.setTokenConfig(other, true, ICollateralPolicy.Tier.BLUE_CHIP, 18);

        PoolKey memory key =
            PoolKey({currency0: weth, currency1: other, fee: 500, tickSpacing: 10, hooks: IHooks(address(0))});
        vm.prank(owner);
        vm.expectRevert(CollateralPolicy.PairMustQuoteInUsdg.selector);
        policy.list(key, _blueChipParams());
    }

    /* ---------------------------------- hooks --------------------------------- */

    function test_swapOnlyHookIsAcceptedWithoutAllowlisting() public {
        PoolKey memory key = _blueChipKey(Fixtures.HOOK_ETH_USDG_DYN);
        _list(key, _blueChipParams());
        assertTrue(policy.acceptsNewPositions(key.toId()));
    }

    function test_hookTouchingRemoveLiquidityNeedsAllowlisting() public {
        PoolKey memory key = _blueChipKey(Fixtures.HOOK_CASHCAT_V2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.HookNotPermitted.selector, Fixtures.HOOK_CASHCAT_V2));
        policy.list(key, _blueChipParams());

        vm.prank(owner);
        policy.setHookAllowlist(Fixtures.HOOK_CASHCAT_V2, true);
        _list(key, _blueChipParams());
        assertTrue(policy.acceptsNewPositions(key.toId()));
    }

    /// @dev Revoking an allowlist entry must bite pools already listed under it — that is the
    ///      whole point of re-checking at deposit time rather than only at listing.
    function test_revokingAnAllowlistedHookStopsNewPositions() public {
        PoolKey memory key = _blueChipKey(Fixtures.HOOK_DOPPLER);
        vm.prank(owner);
        policy.setHookAllowlist(Fixtures.HOOK_DOPPLER, true);
        _list(key, _blueChipParams());

        vm.prank(owner);
        policy.setHookAllowlist(Fixtures.HOOK_DOPPLER, false);

        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.HookNotPermitted.selector, Fixtures.HOOK_DOPPLER));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    /* --------------------------- tighten-only rules --------------------------- */

    function test_stricterTermsAreAccepted() public {
        CollateralPolicy.ListingParams memory p = _blueChipParams();
        p.maxLtvBps = 4000;
        p.ltBps = 5000;
        p.liquidatorBonusBps = 900;
        p.debtCapUsd = 100_000e18;
        p.minPositionUsd = 500e18;

        PoolKey memory key = _blueChipKey(address(0));
        _list(key, p);

        ICollateralPolicy.Terms memory terms = policy.termsOf(key.toId());
        assertEq(terms.maxLtvBps, 4000);
        assertEq(terms.ltBps, 5000);
        assertEq(terms.liquidatorBonusBps, 900);
    }

    /// @dev Each parameter tightens in its own direction; a rule copied from its neighbour
    ///      would let one of these through.
    function test_looserTermsAreRejectedParameterByParameter() public {
        _expectLooser("maxLtv", _tweak(_blueChipParams(), 0));
        _expectLooser("lt", _tweak(_blueChipParams(), 1));
        _expectLooser("liquidatorBonus", _tweak(_blueChipParams(), 2));
        _expectLooser("debtCap", _tweak(_blueChipParams(), 3));
        _expectLooser("minPosition", _tweak(_blueChipParams(), 4));
    }

    function test_maxLtvMustLeaveRoomBelowTheThreshold() public {
        CollateralPolicy.ListingParams memory p = _blueChipParams();
        // Both within the preset, but equal to each other: liquidatable the moment it opens.
        p.maxLtvBps = 6500;
        p.ltBps = 6500;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.NoBorrowingRoom.selector, uint16(6500), uint16(6500)));
        policy.list(_blueChipKey(address(0)), p);
    }

    function test_haircutCannotExceedEverything() public {
        CollateralPolicy.ListingParams memory p = _blueChipParams();
        p.removeHaircutBps = 10_001;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.HaircutTooLarge.selector, uint16(10_001)));
        policy.list(_blueChipKey(address(0)), p);
    }

    /* ---------------------------- freeze and delist --------------------------- */

    function test_freezingStopsNewPositionsButKeepsTerms() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());

        vm.prank(owner);
        policy.setFrozen(key.toId(), true);

        assertFalse(policy.acceptsNewPositions(key.toId()), "frozen pool still accepting");
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolFrozenForNewPositions.selector, key.toId()));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);

        // Terms stay readable: existing loans still need them to compute health and to be
        // liquidated. A frozen pool that stopped answering would strand them.
        assertEq(policy.termsOf(key.toId()).ltBps, 7500, "frozen pool must still report terms");
    }

    function test_freezingIsReversible() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        vm.startPrank(owner);
        policy.setFrozen(key.toId(), true);
        policy.setFrozen(key.toId(), false);
        vm.stopPrank();
        assertTrue(policy.acceptsNewPositions(key.toId()));
    }

    /* --------------------------------- LT ramp -------------------------------- */

    function test_rampFallsLinearlyAndStopsAtTheTarget() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        uint40 start = uint40(block.timestamp + 1 days);
        vm.startPrank(owner);
        policy.setFrozen(poolId, true); // emptying a pool means giving up borrowing room
        policy.scheduleLtRamp(poolId, 3500, start, 10 days);
        vm.stopPrank();

        assertEq(policy.effectiveLt(poolId), 7500, "before the ramp starts nothing changes");

        vm.warp(start);
        assertEq(policy.effectiveLt(poolId), 7500, "at the start the threshold is unchanged");

        vm.warp(start + 5 days);
        assertEq(policy.effectiveLt(poolId), 5500, "halfway should be halfway");

        vm.warp(start + 10 days);
        assertEq(policy.effectiveLt(poolId), 3500, "at the end the target is reached");

        vm.warp(start + 100 days);
        assertEq(policy.effectiveLt(poolId), 3500, "past the end it must not keep falling");
    }

    /// @dev A borrower reads this schedule to know when their position is due to fall. It
    ///      must never move back up, or that reading is worthless.
    function testFuzz_rampNeverRises(
        uint40 elapsed
    ) public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        uint40 start = uint40(block.timestamp + 1);
        vm.startPrank(owner);
        policy.setFrozen(poolId, true);
        policy.scheduleLtRamp(poolId, 1000, start, 30 days);
        vm.stopPrank();

        elapsed = uint40(bound(elapsed, 0, 60 days));
        vm.warp(start);
        uint16 before = policy.effectiveLt(poolId);
        vm.warp(uint256(start) + elapsed);
        assertLe(policy.effectiveLt(poolId), before, "threshold rose during a ramp");
    }

    /// @dev A second ramp starts from where the first one has already reached, so scheduling
    ///      one can never walk the threshold back up.
    function test_aSecondRampCannotUndoTheFirst() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        uint40 start = uint40(block.timestamp + 1);
        vm.startPrank(owner);
        policy.setFrozen(poolId, true);
        policy.scheduleLtRamp(poolId, 5000, start, 10 days);
        vm.stopPrank();

        vm.warp(start + 10 days);
        assertEq(policy.effectiveLt(poolId), 5000);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.LooserThanPreset.selector, "ltTarget"));
        policy.scheduleLtRamp(poolId, 6000, uint40(block.timestamp + 1), 1 days);
    }

    function test_rampMustBeAnnouncedAndHaveDuration() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        vm.warp(1000);
        vm.startPrank(owner);
        policy.setFrozen(poolId, true);

        vm.expectRevert(CollateralPolicy.RampStartInThePast.selector);
        policy.scheduleLtRamp(poolId, 3000, 999, 1 days);

        vm.expectRevert(CollateralPolicy.RampDurationIsZero.selector);
        policy.scheduleLtRamp(poolId, 3000, 1001, 0);
        vm.stopPrank();
    }

    /// @dev Driving the threshold below max LTV empties a pool, which is the point — but a
    ///      pool still open for business would hand out loans that are underwater on arrival.
    ///      So the ramp is allowed, and freezing first is required.
    function test_rampBelowMaxLtvRequiresFreezingFirst() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralPolicy.RampBelowMaxLtvRequiresFreeze.selector, uint16(6500), uint16(6000))
        );
        policy.scheduleLtRamp(poolId, 6000, uint40(block.timestamp + 1), 1 days);

        vm.startPrank(owner);
        policy.setFrozen(poolId, true);
        policy.scheduleLtRamp(poolId, 6000, uint40(block.timestamp + 1), 1 days);
        vm.stopPrank();
    }

    /// @dev The other half of the invariant. Once a pool has ramped past the point where
    ///      borrowing is possible, reopening it must fail rather than admit loans that are
    ///      liquidatable on the block they open.
    function test_cannotUnfreezeAPoolThatHasRampedPastItsBorrowingRoom() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        uint40 start = uint40(block.timestamp + 1);
        vm.startPrank(owner);
        policy.setFrozen(poolId, true);
        policy.scheduleLtRamp(poolId, 3000, start, 1 days);
        vm.stopPrank();

        vm.warp(start + 1 days);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPolicy.UnfreezeWouldLeaveNoBorrowingRoom.selector, uint16(6500), uint16(3000)
            )
        );
        policy.setFrozen(poolId, false);
    }

    function test_updateTermsClearsAnActiveRamp() public {
        PoolKey memory key = _blueChipKey(address(0));
        _list(key, _blueChipParams());
        PoolId poolId = key.toId();

        uint40 start = uint40(block.timestamp + 1);
        vm.startPrank(owner);
        policy.setFrozen(poolId, true);
        policy.scheduleLtRamp(poolId, 3000, start, 10 days);
        vm.stopPrank();
        vm.warp(start + 5 days);

        CollateralPolicy.ListingParams memory p = _blueChipParams();
        p.ltBps = 7000;
        p.maxLtvBps = 6000;
        vm.prank(owner);
        policy.updateTerms(poolId, p);

        assertEq(policy.effectiveLt(poolId), 7000, "new terms did not replace the ramp");
        vm.warp(start + 100 days);
        assertEq(policy.effectiveLt(poolId), 7000, "a cleared ramp is still falling");
    }

    /* --------------------------------- checkPool ------------------------------ */

    function test_marketOnlyTakesItsOwnTier() public {
        PoolKey memory key = _memeKey(address(0));
        _list(key, _memeParams());

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPolicy.WrongTier.selector, ICollateralPolicy.Tier.MEME, ICollateralPolicy.Tier.BLUE_CHIP
            )
        );
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);

        ICollateralPolicy.Terms memory terms = policy.checkPool(key, ICollateralPolicy.Tier.MEME);
        assertEq(terms.maxLtvBps, 3000);
    }

    /* --------------------------------- helpers -------------------------------- */

    function _list(
        PoolKey memory key,
        CollateralPolicy.ListingParams memory p
    ) internal {
        vm.prank(owner);
        policy.list(key, p);
    }

    function _blueChipKey(
        address hooks
    ) internal view returns (PoolKey memory) {
        return PoolKey({currency0: weth, currency1: usdg, fee: 200, tickSpacing: 4, hooks: IHooks(hooks)});
    }

    function _memeKey(
        address hooks
    ) internal view returns (PoolKey memory) {
        return PoolKey({currency0: usdg, currency1: memeToken, fee: 3000, tickSpacing: 60, hooks: IHooks(hooks)});
    }

    function _blueChipParams() internal pure returns (CollateralPolicy.ListingParams memory) {
        TierPresets.Preset memory preset = TierPresets.blueChip();
        return CollateralPolicy.ListingParams({
            maxLtvBps: preset.maxLtvBps,
            ltBps: preset.ltBps,
            liquidatorBonusBps: preset.minLiquidatorBonusBps,
            removeHaircutBps: 0,
            debtCapUsd: preset.maxDebtCapUsd,
            minPositionUsd: preset.minPositionUsd
        });
    }

    function _memeParams() internal pure returns (CollateralPolicy.ListingParams memory) {
        TierPresets.Preset memory preset = TierPresets.meme();
        return CollateralPolicy.ListingParams({
            maxLtvBps: preset.maxLtvBps,
            ltBps: preset.ltBps,
            liquidatorBonusBps: preset.minLiquidatorBonusBps,
            removeHaircutBps: 0,
            debtCapUsd: preset.maxDebtCapUsd,
            minPositionUsd: preset.minPositionUsd
        });
    }

    /// @dev Loosens exactly one parameter past the blue-chip preset.
    function _tweak(
        CollateralPolicy.ListingParams memory p,
        uint256 which
    ) internal pure returns (CollateralPolicy.ListingParams memory) {
        if (which == 0) p.maxLtvBps = 6501;
        if (which == 1) p.ltBps = 7501;
        if (which == 2) p.liquidatorBonusBps = 499;
        if (which == 3) p.debtCapUsd = 500_001e18;
        if (which == 4) p.minPositionUsd = 49e18;
        return p;
    }

    function _expectLooser(
        string memory parameter,
        CollateralPolicy.ListingParams memory p
    ) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.LooserThanPreset.selector, parameter));
        policy.list(_blueChipKey(address(0)), p);
    }
}
