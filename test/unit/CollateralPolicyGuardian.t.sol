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

/// @notice The policy's guardian (ARCHITECTURE §6.5, FAR-68): who names it, what it may do at
///         once, and everything it may not. No network.
contract CollateralPolicyGuardianTest is Test {
    Currency internal usdg = Currency.wrap(RobinhoodChain.USDG);
    Currency internal weth = Currency.wrap(RobinhoodChain.WETH);

    address internal owner = address(0xA11CE);
    address internal guardian = address(0x6A4D);
    address internal stranger = address(0xBAD);

    CollateralPolicy internal policy;

    function setUp() public {
        policy = new CollateralPolicy(usdg, owner);

        vm.startPrank(owner);
        policy.setTokenConfig(usdg, true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(1));
        policy.setTokenConfig(weth, true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(2));
        vm.stopPrank();
    }

    /* ------------------------------- the role --------------------------------- */

    function test_thereIsNoGuardianUntilTheOwnerNamesOne() public view {
        assertEq(policy.guardian(), address(0), "a fresh policy has a guardian");
    }

    function test_theOwnerNamesTheGuardian() public {
        vm.expectEmit(address(policy));
        emit CollateralPolicy.GuardianUpdated(address(0), guardian);
        vm.prank(owner);
        policy.setGuardian(guardian);

        assertEq(policy.guardian(), guardian, "guardian");
    }

    /// @notice `address(0)` is how a guardian is removed: nobody holds the role afterwards.
    function test_theOwnerRemovesTheGuardianWithAddressZero() public {
        _nameGuardian();

        vm.expectEmit(address(policy));
        emit CollateralPolicy.GuardianUpdated(guardian, address(0));
        vm.prank(owner);
        policy.setGuardian(address(0));

        assertEq(policy.guardian(), address(0), "the guardian stayed");
    }

    function test_RevertWhenAStrangerNamesTheGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        policy.setGuardian(stranger);
    }

    /// @notice The guardian cannot hand the role on, nor keep it by naming itself again.
    function test_RevertWhenTheGuardianNamesAGuardian() public {
        _nameGuardian();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        policy.setGuardian(stranger);
    }

    /* --------------------------------- freeze --------------------------------- */

    function test_theGuardianFreezesAPoolAtOnce() public {
        _nameGuardian();
        PoolKey memory key = _list();
        PoolId poolId = key.toId();

        vm.expectEmit(address(policy));
        emit CollateralPolicy.PoolFrozen(poolId, true);
        vm.prank(guardian);
        policy.freeze(poolId);

        assertFalse(policy.acceptsNewPositions(poolId), "the pool still takes new positions");
        assertTrue(policy.listingOf(poolId).frozen, "frozen");
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolFrozenForNewPositions.selector, poolId));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    function test_theOwnerFreezesThroughTheSameFunction() public {
        PoolId poolId = _list().toId();

        vm.prank(owner);
        policy.freeze(poolId);

        assertTrue(policy.listingOf(poolId).frozen, "frozen");
    }

    /// @notice Freezing changes the flag and nothing else: the terms a loan is judged by stay.
    function test_freezingLeavesTheTermsAsTheyWere() public {
        _nameGuardian();
        PoolId poolId = _list().toId();
        bytes32 termsBefore = keccak256(abi.encode(policy.termsOf(poolId)));

        vm.prank(guardian);
        policy.freeze(poolId);

        assertEq(keccak256(abi.encode(policy.termsOf(poolId))), termsBefore, "freezing rewrote the terms");
    }

    /// @notice A second freeze is accepted, so the guardian does not revert behind the owner.
    function test_freezingAFrozenPoolIsAccepted() public {
        _nameGuardian();
        PoolId poolId = _list().toId();
        vm.prank(owner);
        policy.setFrozen(poolId, true);

        vm.prank(guardian);
        policy.freeze(poolId);

        assertTrue(policy.listingOf(poolId).frozen, "frozen");
    }

    function test_RevertWhenTheGuardianFreezesAnUnlistedPool() public {
        _nameGuardian();
        PoolId poolId = _key().toId();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolNotListed.selector, poolId));
        policy.freeze(poolId);
    }

    function test_RevertWhenAStrangerFreezes() public {
        _nameGuardian();
        PoolId poolId = _list().toId();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.NotOwnerOrGuardian.selector, stranger));
        policy.freeze(poolId);
    }

    /// @notice With no guardian named the role is nobody's, the zero address included.
    function test_RevertWhenThereIsNoGuardianAndAddressZeroFreezes() public {
        PoolId poolId = _list().toId();

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.NotOwnerOrGuardian.selector, address(0)));
        policy.freeze(poolId);
    }

    /// @notice A guardian the owner removed has nothing left.
    function test_RevertWhenARemovedGuardianFreezes() public {
        _nameGuardian();
        PoolId poolId = _list().toId();
        vm.prank(owner);
        policy.setGuardian(address(0));

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.NotOwnerOrGuardian.selector, guardian));
        policy.freeze(poolId);
    }

    /// @notice Reopening a pool is the owner's alone, through `setFrozen`.
    function test_RevertWhenTheGuardianUnfreezes() public {
        _nameGuardian();
        PoolId poolId = _list().toId();
        vm.prank(guardian);
        policy.freeze(poolId);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        policy.setFrozen(poolId, false);

        vm.prank(owner);
        policy.setFrozen(poolId, false);
        assertTrue(policy.acceptsNewPositions(poolId), "the owner could not reopen the pool");
    }

    /* ------------------------------ disableToken ------------------------------ */

    /// @notice Only `enabled` changes. The tier, decimals and feed are what positions already
    ///         held are priced with, so they have to survive the token being switched off.
    function test_theGuardianDisablesATokenAndItsListingDataStays() public {
        _nameGuardian();

        vm.expectEmit(address(policy));
        emit CollateralPolicy.TokenConfigured(weth, false, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(2));
        vm.prank(guardian);
        policy.disableToken(weth);

        (bool enabled, ICollateralPolicy.Tier tier, uint8 decimals, address priceFeed) = policy.tokenConfig(weth);
        assertFalse(enabled, "the token is still enabled");
        assertEq(uint8(tier), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier");
        assertEq(decimals, 18, "decimals");
        assertEq(priceFeed, address(2), "price feed");
    }

    /// @notice A pool holding the token stops taking positions, and cannot be listed either.
    function test_aDisabledTokenStopsNewPositionsAndNewListings() public {
        _nameGuardian();
        PoolKey memory key = _list();

        vm.prank(guardian);
        policy.disableToken(weth);

        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, weth));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);

        PoolKey memory other = _key();
        other.fee = 500;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, weth));
        policy.list(other, _params());
    }

    /// @notice The other token of the pair is not touched.
    function test_disablingOneTokenLeavesTheOtherEnabled() public {
        _nameGuardian();

        vm.prank(guardian);
        policy.disableToken(weth);

        (bool enabled,,,) = policy.tokenConfig(usdg);
        assertTrue(enabled, "USDG went with WETH");
    }

    function test_theOwnerDisablesThroughTheSameFunction() public {
        vm.prank(owner);
        policy.disableToken(weth);

        (bool enabled,,,) = policy.tokenConfig(weth);
        assertFalse(enabled, "the token is still enabled");
    }

    /// @notice A token nobody configured stays what it was: disabled, with no tier.
    function test_disablingAnUnconfiguredTokenChangesNothing() public {
        _nameGuardian();
        Currency unknown = Currency.wrap(address(0xDEAD));

        vm.prank(guardian);
        policy.disableToken(unknown);

        (bool enabled, ICollateralPolicy.Tier tier, uint8 decimals, address priceFeed) = policy.tokenConfig(unknown);
        assertFalse(enabled, "enabled");
        assertEq(uint8(tier), uint8(ICollateralPolicy.Tier.NONE), "tier");
        assertEq(decimals, 0, "decimals");
        assertEq(priceFeed, address(0), "price feed");
    }

    function test_RevertWhenAStrangerDisablesAToken() public {
        _nameGuardian();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.NotOwnerOrGuardian.selector, stranger));
        policy.disableToken(weth);
    }

    /// @notice Enabling is the owner's alone, whether the token was disabled or never listed.
    function test_RevertWhenTheGuardianEnablesAToken() public {
        _nameGuardian();
        vm.prank(guardian);
        policy.disableToken(weth);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        policy.setTokenConfig(weth, true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(2));

        vm.prank(owner);
        policy.setTokenConfig(weth, true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(2));
        (bool enabled,,,) = policy.tokenConfig(weth);
        assertTrue(enabled, "the owner could not enable the token again");
    }

    /* ------------------------------- revokeHook ------------------------------- */

    /// @notice Revoking bites a pool already listed behind the hook, as the owner's revoke does.
    function test_theGuardianRevokesAHookAndItsPoolStopsTakingPositions() public {
        _nameGuardian();
        PoolKey memory key = _listBehindAllowlistedHook();
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);

        vm.expectEmit(address(policy));
        emit CollateralPolicy.HookAllowlisted(Fixtures.HOOK_DOPPLER, false);
        vm.prank(guardian);
        policy.revokeHook(Fixtures.HOOK_DOPPLER);

        assertFalse(policy.hookAllowlist(Fixtures.HOOK_DOPPLER), "the hook is still allowlisted");
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.HookNotPermitted.selector, Fixtures.HOOK_DOPPLER));
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    function test_theOwnerRevokesThroughTheSameFunction() public {
        _listBehindAllowlistedHook();

        vm.prank(owner);
        policy.revokeHook(Fixtures.HOOK_DOPPLER);

        assertFalse(policy.hookAllowlist(Fixtures.HOOK_DOPPLER), "the hook is still allowlisted");
    }

    /// @notice One hook is revoked, not the list.
    function test_revokingOneHookLeavesTheOthersAllowlisted() public {
        _nameGuardian();
        _listBehindAllowlistedHook();
        vm.prank(owner);
        policy.setHookAllowlist(Fixtures.HOOK_CASHCAT_V2, true);

        vm.prank(guardian);
        policy.revokeHook(Fixtures.HOOK_DOPPLER);

        assertTrue(policy.hookAllowlist(Fixtures.HOOK_CASHCAT_V2), "another hook was revoked with it");
    }

    /// @notice A hook that passes the bit check never needed the allowlist, so revoking it
    ///         stops nothing. Stopping its pool is `freeze`.
    function test_revokingAHookThatPassesTheBitCheckStopsNothing() public {
        _nameGuardian();
        PoolKey memory key = _key();
        key.hooks = IHooks(Fixtures.HOOK_ETH_USDG_DYN);
        vm.prank(owner);
        policy.list(key, _params());

        vm.prank(guardian);
        policy.revokeHook(Fixtures.HOOK_ETH_USDG_DYN);

        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    function test_RevertWhenAStrangerRevokesAHook() public {
        _nameGuardian();
        _listBehindAllowlistedHook();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.NotOwnerOrGuardian.selector, stranger));
        policy.revokeHook(Fixtures.HOOK_DOPPLER);
    }

    /// @notice Allowlisting follows a review (§6.3) and is the owner's alone.
    function test_RevertWhenTheGuardianAllowlistsAHook() public {
        _nameGuardian();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        policy.setHookAllowlist(Fixtures.HOOK_DOPPLER, true);
    }

    /* --------------------------------- helpers -------------------------------- */

    function _nameGuardian() internal {
        vm.prank(owner);
        policy.setGuardian(guardian);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({currency0: weth, currency1: usdg, fee: 200, tickSpacing: 4, hooks: IHooks(address(0))});
    }

    function _list() internal returns (PoolKey memory key) {
        key = _key();
        vm.prank(owner);
        policy.list(key, _params());
    }

    function _listBehindAllowlistedHook() internal returns (PoolKey memory key) {
        key = _key();
        key.hooks = IHooks(Fixtures.HOOK_DOPPLER);
        vm.startPrank(owner);
        policy.setHookAllowlist(Fixtures.HOOK_DOPPLER, true);
        policy.list(key, _params());
        vm.stopPrank();
    }

    function _params() internal pure returns (CollateralPolicy.ListingParams memory) {
        TierPresets.Preset memory preset = TierPresets.blueChip();
        return CollateralPolicy.ListingParams({
            maxLtvBps: preset.maxLtvBps,
            ltBps: preset.ltBps,
            liquidatorBonusBps: preset.minLiquidatorBonusBps,
            removeHaircutBps: 0,
            debtCapUsdg: preset.maxDebtCapUsdg,
            minPositionUsd: preset.minPositionUsd
        });
    }
}
