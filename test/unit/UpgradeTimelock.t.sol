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
import {MockERC20} from "../mocks/MockERC20.sol";

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

    /* --------------------------------- helpers -------------------------------- */

    function _schedule(
        address newImplementation
    ) internal returns (uint256 eta) {
        vm.prank(owner);
        market.scheduleUpgrade(newImplementation);
        (, eta) = market.pendingUpgrade();
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
