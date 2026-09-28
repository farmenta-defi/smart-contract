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

/// @notice The market's guardian (ARCHITECTURE §4.1, FAR-68): who names it, the one thing it
///         may do, and everything it may not. No network.
/// @dev The dependencies are opaque addresses, as in `FarmentaMarketTest`: nothing here reaches
///      Uniswap.
contract MarketGuardianTest is Test {
    address internal owner = address(0xA11CE);
    address internal guardian = address(0x6A4D);
    address internal stranger = address(0xBAD);

    MockERC20 internal usdg;
    FarmentaMarket internal market;

    function setUp() public {
        usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        FarmentaMarket implementation = new FarmentaMarket(
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
                                owner
                            )
                        )
                    )
                ))
        );
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

    /* --------------------------------- helpers -------------------------------- */

    function _nameGuardian() internal {
        vm.prank(owner);
        market.setGuardian(guardian);
    }
}
