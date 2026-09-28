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
