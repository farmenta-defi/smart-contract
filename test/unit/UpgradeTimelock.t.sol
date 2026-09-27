// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

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
import {MarketLedger} from "../../src/libraries/MarketLedger.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {UnlockedMarketMock} from "../mocks/UnlockedMarketMock.sol";

/// @notice Unit tests for the upgrade timelock (ARCHITECTURE §4.1, §15 no. 9 and 13, FAR-21).
///         No network.
/// @dev The dependencies are opaque addresses, as in `FarmentaMarketTest`: an upgrade reaches
///      none of them.
contract UpgradeTimelockTest is Test {
    event UpgradeScheduled(address indexed newImplementation, uint256 eta);
    event UpgradeCancelled(address indexed newImplementation);

    /// @dev Written out rather than read from the market, so a change to the constant fails here.
    uint256 internal constant DELAY = 2 days;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBAD);

    address internal interestRateModel;
    MockERC20 internal usdg;
    FarmentaMarket internal implementation;
    FarmentaMarket internal market;
    FarmentaMarket internal next;

    function setUp() public {
        usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        interestRateModel = address(new InterestRateModel());
        implementation = _deployImplementation();
        next = _deployImplementation();
        market = FarmentaMarket(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            FarmentaMarket.initialize,
                            (
                                IERC20(address(usdg)),
                                "Farmenta USDG Blue-chip",
                                "fUSDG-BC",
                                ICollateralPolicy.Tier.BLUE_CHIP,
                                owner
                            )
                        )
                    )
                ))
        );
    }

    /* -------------------------------- scheduling ------------------------------ */

    function test_aFreshMarketHasNothingScheduled() public view {
        _assertNothingScheduled();
    }

    function test_schedulingRecordsTheImplementationAndItsEta() public {
        uint256 eta = block.timestamp + DELAY;

        vm.expectEmit(address(market));
        emit UpgradeScheduled(address(next), eta);
        vm.prank(owner);
        market.scheduleUpgrade(address(next));

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(next), "scheduled implementation");
        assertEq(pendingEta, eta, "eta");
    }

    /// @dev The eta is counted from the block that schedules, whenever that is.
    function testFuzz_theEtaIsAFullDelayFromTheSchedulingBlock(
        uint40 scheduledAt
    ) public {
        vm.warp(scheduledAt);

        vm.prank(owner);
        market.scheduleUpgrade(address(next));

        (, uint256 eta) = market.pendingUpgrade();
        assertEq(eta, uint256(scheduledAt) + DELAY, "eta");
    }

    function test_strangerCannotSchedule() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.scheduleUpgrade(address(next));

        _assertNothingScheduled();
    }

    /// @dev Zero is how the ledger says "nothing scheduled", so it cannot also be a schedule.
    function test_schedulingTheZeroAddressIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        market.scheduleUpgrade(address(0));
    }

    /// @dev One upgrade waits at a time. The first keeps its place and its eta.
    function test_aSecondScheduleIsRefusedWhileOneIsPending() public {
        uint256 eta = _schedule(address(next));
        FarmentaMarket other = _deployImplementation();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeAlreadyScheduled.selector, address(next)));
        market.scheduleUpgrade(address(other));

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(next), "the pending upgrade was replaced");
        assertEq(pendingEta, eta, "the pending eta moved");
    }

    /* -------------------------------- cancelling ------------------------------ */

    function test_cancellingClearsTheScheduleAndSaysSo() public {
        _schedule(address(next));

        vm.expectEmit(address(market));
        emit UpgradeCancelled(address(next));
        vm.prank(owner);
        market.cancelUpgrade();

        _assertNothingScheduled();
    }

    function test_strangerCannotCancel() public {
        uint256 eta = _schedule(address(next));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.cancelUpgrade();

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(next), "a stranger cancelled the upgrade");
        assertEq(pendingEta, eta, "eta");
    }

    function test_cancellingWithNothingScheduledIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(FarmentaMarket.NoUpgradeScheduled.selector);
        market.cancelUpgrade();
    }

    /// @notice Cancelling and scheduling again never brings an eta forward.
    /// @dev The only way the owner has to move a pending eta, and it moves it back by as long as
    ///      the first schedule had already waited.
    function testFuzz_reschedulingStartsTheDelayOver(
        uint32 waited
    ) public {
        uint256 firstEta = _schedule(address(next));
        vm.warp(block.timestamp + waited);

        vm.prank(owner);
        market.cancelUpgrade();
        uint256 secondEta = _schedule(address(next));

        assertEq(secondEta, firstEta + waited, "the second schedule did not wait a full delay");
    }

    /* -------------------------------- installing ------------------------------ */

    function test_anUnscheduledImplementationIsRefused() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotScheduled.selector, address(next)));
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(implementation), "an unscheduled upgrade went through");
    }

    /// @dev One second short of the eta is still too early.
    function test_aScheduledUpgradeIsRefusedBeforeItsEta() public {
        uint256 eta = _schedule(address(next));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), eta));
        market.upgradeToAndCall(address(next), "");

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), eta));
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(implementation), "an upgrade went through ahead of its eta");
    }

    function testFuzz_noUpgradeIsInstalledInsideTheDelay(
        uint256 waited
    ) public {
        uint256 eta = _schedule(address(next));
        vm.warp(block.timestamp + bound(waited, 0, DELAY - 1));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), eta));
        market.upgradeToAndCall(address(next), "");
    }

    /// @dev The eta is the first second the upgrade is allowed, not the last it is refused.
    function test_aScheduledUpgradeInstallsAtItsEta() public {
        uint256 eta = _schedule(address(next));
        vm.warp(eta);

        vm.prank(owner);
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(next), "the scheduled implementation was not installed");
        assertEq(uint8(market.tier()), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier lost across upgrade");
        assertEq(market.owner(), owner, "owner lost across upgrade");
    }

    /// @dev Nothing expires a schedule: it stays installable, and visible, until it is installed
    ///      or cancelled.
    function testFuzz_aScheduledUpgradeInstallsAnyTimeFromItsEta(
        uint32 late
    ) public {
        uint256 eta = _schedule(address(next));
        vm.warp(eta + late);

        vm.prank(owner);
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(next), "the scheduled implementation was not installed");
    }

    /// @dev A waited-out schedule lets through the implementation it names and no other.
    function test_anImplementationOtherThanTheScheduledOneIsRefused() public {
        uint256 eta = _schedule(address(next));
        FarmentaMarket other = _deployImplementation();
        vm.warp(eta);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotScheduled.selector, address(other)));
        market.upgradeToAndCall(address(other), "");

        assertEq(_installed(), address(implementation), "an unscheduled upgrade went through");
        (address pending,) = market.pendingUpgrade();
        assertEq(pending, address(next), "the refused upgrade spent the schedule");
    }

    function test_aCancelledUpgradeCannotBeInstalled() public {
        uint256 eta = _schedule(address(next));
        vm.prank(owner);
        market.cancelUpgrade();
        vm.warp(eta);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotScheduled.selector, address(next)));
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(implementation), "a cancelled upgrade went through");
    }

    /// @dev The time a cancelled schedule had waited buys the next one nothing.
    function test_anUpgradeScheduledAgainAfterACancelWaitsTheWholeDelayAgain() public {
        uint256 firstEta = _schedule(address(next));
        vm.warp(firstEta);
        vm.prank(owner);
        market.cancelUpgrade();

        uint256 secondEta = _schedule(address(next));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), secondEta));
        market.upgradeToAndCall(address(next), "");
    }

    /// @dev The upgrade spends its schedule. Otherwise an implementation installed once could be
    ///      put back at any later time, in one transaction, after the market had moved on from it.
    function test_anInstalledUpgradeSpendsItsSchedule() public {
        vm.warp(_schedule(address(next)));
        vm.prank(owner);
        market.upgradeToAndCall(address(next), "");

        _assertNothingScheduled();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotScheduled.selector, address(next)));
        market.upgradeToAndCall(address(next), "");
    }

    /// @dev Zero is what an empty schedule holds, and must not match it.
    function test_theZeroAddressDoesNotMatchAnEmptySchedule() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotScheduled.selector, address(0)));
        market.upgradeToAndCall(address(0), "");
    }

    /// @dev The schedule says what may be installed, not who may install it.
    function test_strangerCannotInstallAScheduledUpgrade() public {
        vm.warp(_schedule(address(next)));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(implementation), "a stranger installed the upgrade");
    }

    /// @notice Handing the market to a new owner neither drops a schedule nor shortens it.
    function test_aNewOwnerInheritsTheScheduleAndItsEta() public {
        uint256 eta = _schedule(address(next));

        vm.prank(owner);
        market.transferOwnership(stranger);
        vm.prank(stranger);
        market.acceptOwnership();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), eta));
        market.upgradeToAndCall(address(next), "");

        vm.warp(eta);
        vm.prank(stranger);
        market.upgradeToAndCall(address(next), "");
        assertEq(_installed(), address(next), "the scheduled implementation was not installed");
    }

    /* ---------------------------------- pause --------------------------------- */

    /// @notice §4.1: the delay that guards upgrades must not reach the emergency lever.
    /// @dev Everything here happens in the block that scheduled the upgrade, a full delay ahead
    ///      of its eta.
    function test_pauseAndUnpauseDoNotWaitForTheQueue() public {
        uint256 eta = _schedule(address(next));

        vm.prank(owner);
        market.pause();
        assertTrue(market.paused(), "pause waited");

        vm.prank(owner);
        market.unpause();
        assertFalse(market.paused(), "unpause waited");

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(next), "pausing touched the schedule");
        assertEq(pendingEta, eta, "pausing moved the eta");
    }

    /// @notice A pause neither stops the queue nor lets an upgrade through early.
    function test_aPausedMarketRunsItsQueueOnTheSameClock() public {
        vm.prank(owner);
        market.pause();

        uint256 eta = _schedule(address(next));
        vm.prank(owner);
        market.cancelUpgrade();
        _assertNothingScheduled();

        eta = _schedule(address(next));
        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), eta));
        market.upgradeToAndCall(address(next), "");

        vm.warp(eta);
        vm.prank(owner);
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(next), "a paused market could not be upgraded");
        assertTrue(market.paused(), "the upgrade lifted the pause");
    }

    /* -------------------------------- the delay ------------------------------- */

    function test_theDelayIsTwoDays() public view {
        assertEq(market.TIMELOCK_DELAY(), DELAY, "delay read through the proxy");
        assertEq(implementation.TIMELOCK_DELAY(), DELAY, "delay read from the implementation");
    }

    /// @notice No storage write changes the delay, so no owner transaction can.
    /// @dev Every transaction the owner sends the proxy can only write the proxy's storage. The
    ///      market's namespace is overwritten here from its first slot to past its last, the queue
    ///      included, and the delay that guards the next upgrade is still the whole two days.
    function test_theDelayIsNotReadFromStorage() public {
        for (uint256 i = 0; i < 16; ++i) {
            vm.store(address(market), bytes32(uint256(MarketLedger.LOCATION) + i), bytes32(0));
        }
        assertEq(market.TIMELOCK_DELAY(), DELAY, "delay read from zeroed storage");

        uint256 eta = _schedule(address(next));
        assertEq(eta, block.timestamp + DELAY, "a zeroed namespace shortened the delay");
    }

    /// @notice The owner's other calls leave the delay, and a pending eta, where they were.
    function test_noOwnerCallShortensTheDelayOrAPendingEta() public {
        uint256 eta = _schedule(address(next));

        vm.startPrank(owner);
        market.pause();
        market.unpause();
        market.withdrawReserves(0, owner);
        market.rescueUnaccountedEth(owner);
        market.transferOwnership(stranger);
        market.transferOwnership(owner);
        vm.stopPrank();

        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(next), "the schedule changed");
        assertEq(pendingEta, eta, "the eta moved");
        assertEq(market.TIMELOCK_DELAY(), DELAY, "the delay changed");
    }

    /// @notice Changing the delay takes an upgrade, and that upgrade waits out the delay it removes.
    function test_theDelayOnlyChangesThroughAnUpgradeThatWaitedItOut() public {
        address unlocked = address(new UnlockedMarketMock());
        uint256 eta = _schedule(unlocked);

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, unlocked, eta));
        market.upgradeToAndCall(unlocked, "");
        assertEq(market.TIMELOCK_DELAY(), DELAY, "the delay changed ahead of the upgrade");

        vm.warp(eta);
        vm.prank(owner);
        market.upgradeToAndCall(unlocked, "");
        assertEq(market.TIMELOCK_DELAY(), 0, "the replacement's delay is not in force");
    }

    /* --------------------------------- helpers -------------------------------- */

    function _schedule(
        address newImplementation
    ) internal returns (uint256 eta) {
        vm.prank(owner);
        market.scheduleUpgrade(newImplementation);
        (, eta) = market.pendingUpgrade();
    }

    /// @dev The ERC-1967 implementation slot: what the proxy actually runs.
    function _installed() internal view returns (address) {
        return address(
            uint160(
                uint256(vm.load(address(market), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))
            )
        );
    }

    function _assertNothingScheduled() internal view {
        (address pending, uint256 eta) = market.pendingUpgrade();
        assertEq(pending, address(0), "an upgrade is scheduled");
        assertEq(eta, 0, "an eta is left behind");
    }

    function _deployImplementation() internal returns (FarmentaMarket) {
        return new FarmentaMarket(
            IPositionManager(payable(address(0xB0B))),
            ICollateralPolicy(address(0xC0DE)),
            IPositionValuer(address(0xDEAD)),
            IPriceOracle(address(0x0A11CE)),
            IInterestRateModel(interestRateModel)
        );
    }
}
