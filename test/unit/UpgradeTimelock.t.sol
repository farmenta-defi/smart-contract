// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
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
import {
    MetamorphicFactoryMock,
    OtherImplementationMock,
    RemovableImplementationMock
} from "../mocks/MetamorphicFactoryMock.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {UnlockedMarketMock} from "../mocks/UnlockedMarketMock.sol";

/// @notice Unit tests for the upgrade timelock (ARCHITECTURE §4.1, §15 no. 9 and 13, FAR-21).
///         No network.
/// @dev The dependencies are opaque addresses, as in `FarmentaMarketTest`: an upgrade reaches
///      none of them.
contract UpgradeTimelockTest is Test {
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
        emit FarmentaMarket.UpgradeScheduled(address(next), eta);
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
        emit FarmentaMarket.UpgradeCancelled(address(next));
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

    /* --------------------------------- the code ------------------------------- */

    /// @notice A schedule is held to the code it was given, not to the address alone.
    function test_schedulingRecordsTheHashOfTheCodeItWasGiven() public {
        _schedule(address(next));

        assertEq(market.pendingUpgradeCodehash(), address(next).codehash, "code hash");
    }

    /// @dev Two days with nothing to read, and anything at all installed after them.
    function test_anAddressWithNoCodeIsRefusedAtScheduling() public {
        address empty = new MetamorphicFactoryMock().where();
        assertEq(empty.code.length, 0, "the address holds code");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.ImplementationHasNoCode.selector, empty));
        market.scheduleUpgrade(empty);

        _assertNothingScheduled();
    }

    /// @notice An account that only points at code is refused, whatever it points at.
    /// @dev The 23 bytes of an EIP-7702 delegation. Their hash would not move when the account is
    ///      pointed elsewhere, so a schedule held to it would be held to nothing.
    function test_anAccountThatOnlyPointsAtCodeIsRefusedAtScheduling() public {
        address delegated = address(0xE0A);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(next)));
        assertEq(delegated.code.length, 23, "the account does not hold a delegation");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.ImplementationIsAPointer.selector, delegated));
        market.scheduleUpgrade(delegated);

        _assertNothingScheduled();
    }

    /// @notice Other code under the scheduled address is refused, and the refusal spends nothing.
    function test_codeThatChangedSinceItWasScheduledIsRefused() public {
        uint256 eta = _schedule(address(next));
        bytes32 scheduled = address(next).codehash;
        vm.warp(eta);

        vm.etch(address(next), type(OtherImplementationMock).runtimeCode);
        bytes32 found = address(next).codehash;
        assertTrue(found != scheduled, "the code did not change");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.ImplementationCodeChanged.selector, address(next), scheduled, found)
        );
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(implementation), "other code than was scheduled went through");
        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(next), "the refused upgrade spent the schedule");
        assertEq(pendingEta, eta, "the refused upgrade moved the eta");
        assertEq(market.pendingUpgradeCodehash(), scheduled, "the refused upgrade moved the code hash");
    }

    /// @dev Too early is said first. Both refuse; this pins which one a caller is told.
    function test_codeThatChangedBeforeTheEtaIsRefusedAsTooEarly() public {
        uint256 eta = _schedule(address(next));
        vm.etch(address(next), type(OtherImplementationMock).runtimeCode);

        vm.warp(eta - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UpgradeNotReady.selector, address(next), eta));
        market.upgradeToAndCall(address(next), "");
    }

    /// @notice An install that fails after the queue let it through leaves the schedule whole.
    /// @dev The vault's asset holds code and is no implementation: the queue passes it and the
    ///      UUPS check refuses it, which reverts the spending with everything else.
    function test_anInstallRefusedAfterTheQueueLeavesTheScheduleAsItWas() public {
        uint256 eta = _schedule(address(usdg));
        bytes32 scheduled = address(usdg).codehash;
        vm.warp(eta);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, address(usdg)));
        market.upgradeToAndCall(address(usdg), "");

        assertEq(_installed(), address(implementation), "something that is no implementation went through");
        (address pending, uint256 pendingEta) = market.pendingUpgrade();
        assertEq(pending, address(usdg), "the failed install spent the schedule");
        assertEq(pendingEta, eta, "the failed install moved the eta");
        assertEq(market.pendingUpgradeCodehash(), scheduled, "the failed install moved the code hash");
    }

    /// @dev An address emptied after it was scheduled does not match what was scheduled either.
    function test_codeRemovedSinceItWasScheduledIsRefused() public {
        uint256 eta = _schedule(address(next));
        bytes32 scheduled = address(next).codehash;
        vm.warp(eta);

        vm.etch(address(next), "");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                FarmentaMarket.ImplementationCodeChanged.selector, address(next), scheduled, address(next).codehash
            )
        );
        market.upgradeToAndCall(address(next), "");

        assertEq(_installed(), address(implementation), "an emptied address went through");
    }

    /// @notice A cancelled schedule leaves no hash behind for the next one to inherit.
    function test_aScheduleAfterACancelIsHeldToItsOwnCode() public {
        _schedule(address(next));
        vm.prank(owner);
        market.cancelUpgrade();
        assertEq(market.pendingUpgradeCodehash(), bytes32(0), "cancelling left the code hash behind");

        address other = address(new UnlockedMarketMock());
        assertTrue(other.codehash != address(next).codehash, "the two implementations share their code");
        uint256 eta = _schedule(other);
        assertEq(market.pendingUpgradeCodehash(), other.codehash, "the second schedule kept the first one's hash");

        vm.warp(eta);
        vm.prank(owner);
        market.upgradeToAndCall(other, "");
        assertEq(_installed(), other, "the second schedule was not installed");
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
        assertEq(market.pendingUpgradeCodehash(), bytes32(0), "a code hash is left behind");
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

/// @notice The code binding against code that lives for one transaction only (FAR-21, review of
///         PR #42). No network.
/// @dev `setUp` is the scheduling transaction: a factory that owns the market puts removable code
///      at an address, schedules that address and removes the code again. A check for code made
///      while scheduling passes, and the address is empty from then on. Only the hash the schedule
///      holds tells what may be installed there.
contract UpgradeTimelockOneTransactionCodeTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    MetamorphicFactoryMock internal factory;
    FarmentaMarket internal implementation;
    FarmentaMarket internal market;
    address internal scheduled;
    uint256 internal eta;

    function setUp() public {
        MockERC20 usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        factory = new MetamorphicFactoryMock();
        implementation = new FarmentaMarket(
            IPositionManager(payable(address(0xB0B))),
            ICollateralPolicy(address(0xC0DE)),
            IPositionValuer(address(0xDEAD)),
            IPriceOracle(address(0x0A11CE)),
            IInterestRateModel(address(new InterestRateModel()))
        );
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
                                address(factory)
                            )
                        )
                    )
                ))
        );

        scheduled = factory.deployScheduleAndRemove(market);
        (, eta) = market.pendingUpgrade();
    }

    /// @dev What the scheduling transaction left: a schedule, its hash, and nothing to read.
    function test_theScheduledCodeIsGoneOnceItsTransactionIsOver() public view {
        (address pending,) = market.pendingUpgrade();
        assertEq(pending, scheduled, "scheduled implementation");
        assertEq(scheduled.code.length, 0, "the scheduled code is still there");
        assertEq(market.pendingUpgradeCodehash(), keccak256(type(RemovableImplementationMock).runtimeCode), "code hash");
    }

    function test_anAddressLeftEmptyIsRefused() public {
        vm.warp(eta);

        bytes memory refusal = abi.encodeWithSelector(
            FarmentaMarket.ImplementationCodeChanged.selector,
            scheduled,
            market.pendingUpgradeCodehash(),
            scheduled.codehash
        );

        vm.prank(address(factory));
        vm.expectRevert(refusal);
        market.upgradeToAndCall(scheduled, "");

        assertEq(_installed(), address(implementation), "an empty address went through");
    }

    /// @notice Other code put at the scheduled address after the delay is refused.
    function test_otherCodeAtTheScheduledAddressIsRefused() public {
        vm.warp(eta);
        address again = factory.deploy(type(OtherImplementationMock).runtimeCode);
        assertEq(again, scheduled, "the factory landed elsewhere");

        bytes memory refusal = abi.encodeWithSelector(
            FarmentaMarket.ImplementationCodeChanged.selector,
            scheduled,
            market.pendingUpgradeCodehash(),
            scheduled.codehash
        );

        vm.prank(address(factory));
        vm.expectRevert(refusal);
        market.upgradeToAndCall(scheduled, "");

        assertEq(_installed(), address(implementation), "other code than was scheduled went through");
    }

    /// @notice KNOWN LIMIT, not a guarantee: code put in place, installed and removed inside one
    ///         transaction leaves the market running an empty address, and whatever is put there
    ///         next runs with no schedule and no delay.
    /// @dev Nothing the market can check tells code created in the installing transaction from
    ///      code that was there before it. What gives it away is off chain: the scheduled address
    ///      held no code for the whole delay. A pending upgrade like that is to be treated as
    ///      hostile (README point 1). `beforeTestSetup` runs the install as its own transaction.
    function test_codeThatCanRemoveItselfIsReplacedOnceItIsInstalled() public {
        assertEq(_installed(), scheduled, "the install did not go through");
        assertEq(scheduled.code.length, 0, "the installed code is still there");

        factory.deploy(type(OtherImplementationMock).runtimeCode);

        assertTrue(OtherImplementationMock(address(market)).other(), "the market does not run the code put there");
    }

    function beforeTestSetup(
        bytes4 testSelector
    ) public view returns (bytes[] memory transactions) {
        if (testSelector == this.test_codeThatCanRemoveItselfIsReplacedOnceItIsInstalled.selector) {
            transactions = new bytes[](1);
            transactions[0] = abi.encodeCall(this.installAndRemoveInOneTransaction, ());
        }
    }

    function installAndRemoveInOneTransaction() public {
        vm.warp(eta);
        factory.deployInstallAndRemove(market);
    }

    /// @dev The schedule is held to the code, not to one deployment of it.
    function test_theScheduledCodePutBackIsInstalled() public {
        vm.warp(eta);
        factory.deploy(type(RemovableImplementationMock).runtimeCode);

        vm.prank(address(factory));
        market.upgradeToAndCall(scheduled, "");

        assertEq(_installed(), scheduled, "the scheduled code was not installed");
    }

    function _installed() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(market), IMPLEMENTATION_SLOT))));
    }
}
