// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The market's guardian (ARCHITECTURE §4.1, FAR-68): who names it, the one thing it
///         may do, and everything it may not. No network.
/// @dev The dependencies are opaque addresses, as in `FarmentaMarketTest`: nothing here reaches
///      Uniswap.
contract MarketGuardianTest is Test {
    address internal owner = address(0xA11CE);
    address internal guardian = address(0x6A4D);
    address internal stranger = address(0xBAD);

    MockERC20 internal usdg;
    FarmentaMarket internal implementation;
    FarmentaMarket internal market;

    function setUp() public {
        usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        implementation = new FarmentaMarket(
            IPositionManager(payable(address(0xB0B))),
            ICollateralPolicy(address(0xC0DE)),
            IPositionValuer(address(0xDEAD)),
            IPriceOracle(address(0x0A11CE)),
            IInterestRateModel(address(new InterestRateModel()))
        );
        market = _deployProxy(address(0));
    }

    /* ------------------------------- initialize ------------------------------- */

    /// @notice A proxy deployed for a timelock owner has its guardian from the first block:
    ///         named in `initialize`, able to pause before the owner has made a single call.
    function test_initializeNamesTheGuardian() public {
        vm.expectEmit();
        emit FarmentaMarket.GuardianUpdated(address(0), guardian);
        FarmentaMarket guarded = _deployProxy(guardian);

        assertEq(guarded.guardian(), guardian, "guardian");
        assertEq(guarded.owner(), owner, "owner");

        vm.prank(guardian);
        guarded.pause();
        assertTrue(guarded.paused(), "the pause did not take");
    }

    /// @notice Initialised without a guardian, a market announces none.
    function test_initializeWithoutAGuardianEmitsNoGuardianEvent() public {
        vm.recordLogs();
        FarmentaMarket unguarded = _deployProxy(address(0));

        assertEq(unguarded.guardian(), address(0), "guardian");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != FarmentaMarket.GuardianUpdated.selector, "GuardianUpdated was emitted");
        }
    }

    /* ------------------------------- the role --------------------------------- */

    function test_thereIsNoGuardianUntilTheOwnerNamesOne() public view {
        assertEq(market.guardian(), address(0), "a fresh market has a guardian");
    }

    function test_theOwnerNamesTheGuardian() public {
        vm.expectEmit(address(market));
        emit FarmentaMarket.GuardianUpdated(address(0), guardian);
        vm.prank(owner);
        market.setGuardian(guardian);

        assertEq(market.guardian(), guardian, "guardian");
    }

    /// @notice `address(0)` is how a guardian is removed: nobody holds the role afterwards.
    function test_theOwnerRemovesTheGuardianWithAddressZero() public {
        _nameGuardian();

        vm.expectEmit(address(market));
        emit FarmentaMarket.GuardianUpdated(guardian, address(0));
        vm.prank(owner);
        market.setGuardian(address(0));

        assertEq(market.guardian(), address(0), "the guardian stayed");
    }

    /// @notice Naming a guardian does not wait for a pause to end, nor start one.
    function test_theGuardianCanBeReplacedWhilePaused() public {
        _nameGuardian();
        vm.prank(owner);
        market.pause();

        vm.prank(owner);
        market.setGuardian(stranger);

        assertEq(market.guardian(), stranger, "guardian");
        assertTrue(market.paused(), "replacing the guardian lifted the pause");
    }

    function test_RevertWhenAStrangerNamesTheGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.setGuardian(stranger);
    }

    /// @notice The guardian cannot hand the role on, nor keep it by naming itself again.
    function test_RevertWhenTheGuardianNamesAGuardian() public {
        _nameGuardian();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        market.setGuardian(stranger);
    }

    /* ---------------------------------- pause --------------------------------- */

    /// @notice `Paused` names the caller, which is how a reader of logs tells a guardian's
    ///         pause from the owner's.
    function test_theGuardianPausesAtOnce() public {
        _nameGuardian();

        vm.expectEmit(address(market));
        emit PausableUpgradeable.Paused(guardian);
        vm.prank(guardian);
        market.pause();

        assertTrue(market.paused(), "the pause did not take");
    }

    /// @notice What the guardian's pause stops is what the owner's stops: the vault takes no
    ///         money, and still gives lenders theirs back.
    function test_aGuardianPauseStopsDepositsButNotWithdrawals() public {
        _nameGuardian();
        address lender = address(0x1E4DE2);
        usdg.mint(lender, 1000e6);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(500e6, lender);
        vm.stopPrank();

        vm.prank(guardian);
        market.pause();

        vm.startPrank(lender);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        market.deposit(100e6, lender);
        market.withdraw(100e6, lender, lender);
        vm.stopPrank();

        assertEq(usdg.balanceOf(lender), 600e6, "a guardian's pause trapped a lender's assets");
    }

    function test_theOwnerStillPausesAndUnpauses() public {
        _nameGuardian();

        vm.prank(owner);
        market.pause();
        assertTrue(market.paused(), "the pause did not take");

        vm.prank(owner);
        market.unpause();
        assertFalse(market.paused(), "the unpause did not take");
    }

    /// @notice The guardian starts a pause and the owner ends it.
    function test_theOwnerLiftsAGuardiansPause() public {
        _nameGuardian();
        vm.prank(guardian);
        market.pause();

        vm.prank(owner);
        market.unpause();

        assertFalse(market.paused(), "the owner could not lift the guardian's pause");
    }

    function test_RevertWhenTheGuardianUnpauses() public {
        _nameGuardian();
        vm.prank(guardian);
        market.pause();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        market.unpause();

        assertTrue(market.paused(), "the guardian lifted the pause");
    }

    function test_RevertWhenAStrangerPauses() public {
        _nameGuardian();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotOwnerOrGuardian.selector, stranger));
        market.pause();
    }

    /// @notice With no guardian named the role is nobody's, the zero address included.
    function test_RevertWhenThereIsNoGuardianAndAddressZeroPauses() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotOwnerOrGuardian.selector, address(0)));
        market.pause();
    }

    /// @notice A guardian the owner removed or replaced has nothing left.
    function test_RevertWhenAReplacedGuardianPauses() public {
        _nameGuardian();
        vm.prank(owner);
        market.setGuardian(stranger);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotOwnerOrGuardian.selector, guardian));
        market.pause();
    }

    /// @notice A pause on a paused market is refused as it always was, whoever asks.
    function test_RevertWhenTheGuardianPausesAPausedMarket() public {
        _nameGuardian();
        vm.prank(owner);
        market.pause();

        vm.prank(guardian);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        market.pause();
    }

    /* ------------------------- what stays the owner's ------------------------- */

    /// @notice The guardian holds `pause` and no other function of the owner's.
    function test_RevertWhenTheGuardianCallsAnOwnerFunction() public {
        _nameGuardian();
        bytes memory refused = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);

        vm.startPrank(guardian);
        vm.expectRevert(refused);
        market.scheduleUpgrade(address(market));

        vm.expectRevert(refused);
        market.cancelUpgrade();

        vm.expectRevert(refused);
        market.upgradeToAndCall(address(market), "");

        vm.expectRevert(refused);
        market.withdrawReserves(1, guardian);

        vm.expectRevert(refused);
        market.rescueUnaccountedToken(1, guardian);

        vm.expectRevert(refused);
        market.rescueUnaccountedEth(guardian);

        vm.expectRevert(refused);
        market.transferOwnership(guardian);

        vm.expectRevert(refused);
        market.renounceOwnership();
        vm.stopPrank();
    }

    /* --------------------------------- helpers -------------------------------- */

    function _nameGuardian() internal {
        vm.prank(owner);
        market.setGuardian(guardian);
    }

    function _deployProxy(
        address guardian_
    ) internal returns (FarmentaMarket) {
        bytes memory init = abi.encodeCall(
            FarmentaMarket.initialize,
            (
                IERC20(address(usdg)),
                "Farmenta USDG Blue-chip",
                "fUSDG-BC",
                ICollateralPolicy.Tier.BLUE_CHIP,
                owner,
                guardian_
            )
        );
        return FarmentaMarket(payable(address(new ERC1967Proxy(address(implementation), init))));
    }
}
