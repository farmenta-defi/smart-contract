// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";

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

    /* --------------------------------- helpers -------------------------------- */

    function _nameGuardian() internal {
        vm.prank(owner);
        policy.setGuardian(guardian);
    }
}
