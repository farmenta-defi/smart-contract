// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Unit tests for the market's proxy setup, ownership and storage layout. No network.
/// @dev The dependencies are opaque addresses here: nothing in this file reaches Uniswap. The
///      custody paths that do are exercised against real positions under `test/fork/`.
contract FarmentaMarketTest is Test {
    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBAD);

    address internal posm = address(0xB0B);
    address internal policy = address(0xC0DE);
    address internal valuer = address(0xDEAD);

    MockERC20 internal usdg;
    FarmentaMarket internal implementation;
    FarmentaMarket internal market;

    function setUp() public {
        usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        implementation = _deployImplementation();
        market = _deployProxy(ICollateralPolicy.Tier.BLUE_CHIP);
    }

    /* -------------------------------- deployment ------------------------------ */

    function test_initializeStoresTheVaultIdentityAndTier() public view {
        assertEq(market.name(), "Farmenta USDG Blue-chip", "share name");
        assertEq(market.symbol(), "fUSDG-BC", "share symbol");
        assertEq(market.asset(), address(usdg), "vault asset");
        assertEq(uint8(market.tier()), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier");
        assertEq(market.owner(), owner, "owner");
    }

    /// @dev The dependencies live in the implementation's bytecode, so a proxy must read the
    ///      same values without ever having been told them.
    function test_proxyInheritsTheImplementationsImmutables() public view {
        assertEq(address(market.positionManager()), posm, "positionManager");
        assertEq(address(market.policy()), policy, "policy");
        assertEq(address(market.valuer()), valuer, "valuer");
    }

    /// @dev Share decimals are the asset's plus the offset. USDG has 6, so 9 is the answer;
    ///      an 18 here would mean `__ERC4626_init` failed to read the asset and fell back.
    function test_shareDecimalsCarryTheOffset() public view {
        assertEq(market.decimals(), RobinhoodChain.USDG_DECIMALS + 3, "decimals offset lost");
    }

    /// @dev An implementation left initialisable can be seized by anyone and then used to
    ///      drive `upgradeToAndCall` on itself, which is how UUPS implementations get bricked.
    function test_implementationCannotBeInitialised() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(IERC20(address(usdg)), "x", "x", ICollateralPolicy.Tier.BLUE_CHIP, owner);
    }

    function test_cannotInitialiseTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        market.initialize(IERC20(address(usdg)), "x", "x", ICollateralPolicy.Tier.BLUE_CHIP, owner);
    }

    /// @dev `Tier.NONE` is the unconfigured value. A market holding it would match every
    ///      unlisted pool's tier, which is the one comparison that must never succeed.
    function test_tierNoneIsRejected() public {
        FarmentaMarket fresh = _deployImplementation();
        vm.expectRevert(FarmentaMarket.TierNotSet.selector);
        new ERC1967Proxy(address(fresh), _initData(ICollateralPolicy.Tier.NONE));
    }

    function test_zeroDependencyIsRejected() public {
        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(IPositionManager(payable(address(0))), ICollateralPolicy(policy), IPositionValuer(valuer));

        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(IPositionManager(payable(posm)), ICollateralPolicy(address(0)), IPositionValuer(valuer));

        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(IPositionManager(payable(posm)), ICollateralPolicy(policy), IPositionValuer(address(0)));
    }

    /* --------------------------------- upgrades ------------------------------- */

    function test_ownerCanUpgrade() public {
        FarmentaMarket next = _deployImplementation();

        vm.prank(owner);
        market.upgradeToAndCall(address(next), "");

        // State survives: the proxy still knows its tier and its owner.
        assertEq(uint8(market.tier()), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier lost across upgrade");
        assertEq(market.owner(), owner, "owner lost across upgrade");
    }

    /// @dev The whole trust story of §15 no. 9 rests on this one modifier.
    function test_strangerCannotUpgrade() public {
        FarmentaMarket next = _deployImplementation();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.upgradeToAndCall(address(next), "");
    }

    /// @dev `onlyProxy` on the upgrade entry point. An implementation that could be upgraded
    ///      through its own address is the other half of the bricking story that
    ///      `_disableInitializers` covers.
    function test_implementationCannotBeUpgradedThroughItself() public {
        FarmentaMarket next = _deployImplementation();
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(next), "");
    }

    /* ---------------------------------- pause --------------------------------- */

    function test_onlyOwnerCanPause() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.pause();

        vm.prank(owner);
        market.pause();
        assertTrue(market.paused(), "pause did not take");

        vm.prank(owner);
        market.unpause();
        assertFalse(market.paused(), "unpause did not take");
    }

    /// @notice Pausing stops the vault taking money, and still lets lenders take theirs out.
    /// @dev The same asymmetry the collateral side uses. §5.2 makes pausing the only
    ///      sequencer-downtime lever this chain offers, so continuing to accept deposits
    ///      during one would be the wrong half to leave running; refusing to return them
    ///      would be the wrong half to stop.
    function test_pausingStopsVaultDepositsButNotWithdrawals() public {
        address lender = address(0x1E4DE2);
        usdg.mint(lender, 1000e6);

        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(500e6, lender);
        vm.stopPrank();

        vm.prank(owner);
        market.pause();

        vm.startPrank(lender);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        market.deposit(100e6, lender);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        market.mint(100e6, lender);

        market.withdraw(100e6, lender, lender);
        vm.stopPrank();

        assertEq(usdg.balanceOf(lender), 600e6, "a paused market trapped a lender's assets");
    }

    /// @notice The market accepts native ETH.
    /// @dev Pools whose currency0 is `address(0)` pay out in ETH, so `TAKE_PAIR` will send it
    ///      here once fees, liquidity decreases and liquidations exist (§4.1). Nothing routes
    ///      ETH here yet; a market that rejected the first payout it was handed would fail at
    ///      exactly the wrong moment.
    function test_marketAcceptsNativeEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertTrue(ok, "market refused native ETH");
        assertEq(address(market).balance, 1 ether, "ETH did not land");
    }

    /// @dev Ownership moves in two steps, so a typo in the new owner cannot lock the market.
    function test_ownershipTransferIsTwoStep() public {
        vm.prank(owner);
        market.transferOwnership(stranger);
        assertEq(market.owner(), owner, "ownership moved before it was accepted");

        vm.prank(stranger);
        market.acceptOwnership();
        assertEq(market.owner(), stranger, "ownership did not move");
    }

    /* -------------------------------- provenance ------------------------------ */

    /// @notice Only the Uniswap PositionManager may hand this market an NFT.
    /// @dev Without this the callback would accept any ERC-721. The policy and the valuer
    ///      both key off `tokenId` alone, so a token of the depositor's own making would be
    ///      recorded as collateral while those two read an entirely different contract.
    function test_onERC721ReceivedRejectsAnyOtherCaller() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotThePositionManager.selector, stranger));
        market.onERC721Received(stranger, stranger, 1, "");
    }

    /* --------------------------------- storage -------------------------------- */

    /// @notice The declared slot really is the ERC-7201 slot for this namespace.
    /// @dev Recomputed here rather than copied: a hand-typed constant that is merely
    ///      plausible would place every variable somewhere unintended, and nothing else in
    ///      the suite would notice.
    function test_storageSlotMatchesTheErc7201Formula() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("farmenta.storage.Market")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, _marketStorageLocation(), "namespace slot is not the ERC-7201 one");
    }

    /// @notice State actually lands in the namespace, not in slot zero.
    /// @dev `tier` is the first field, so it sits at the namespace root. Reading it back
    ///      through `vm.load` proves the assembly in `_marketStorage` points where the
    ///      NatSpec claims, which no external getter can show on its own.
    function test_stateLandsInTheNamespacedSlot() public view {
        bytes32 stored = vm.load(address(market), _marketStorageLocation());
        assertEq(uint256(stored), uint256(ICollateralPolicy.Tier.BLUE_CHIP), "tier is not in the namespace");

        // And slot 0 stays untouched, which is what the namespace exists to guarantee.
        assertEq(uint256(vm.load(address(market), bytes32(0))), 0, "state leaked into slot 0");
    }

    function test_unknownPositionHasNoLoan() public view {
        FarmentaMarket.Loan memory loan = market.loanOf(12_345);
        assertEq(loan.owner, address(0), "phantom loan owner");
        assertEq(loan.debtShares, 0, "phantom debt");
    }

    /* --------------------------------- helpers -------------------------------- */

    function _marketStorageLocation() internal pure returns (bytes32) {
        return 0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;
    }

    function _deployImplementation() internal returns (FarmentaMarket) {
        return new FarmentaMarket(IPositionManager(payable(posm)), ICollateralPolicy(policy), IPositionValuer(valuer));
    }

    function _deployProxy(
        ICollateralPolicy.Tier tier
    ) internal returns (FarmentaMarket) {
        return FarmentaMarket(payable(address(new ERC1967Proxy(address(implementation), _initData(tier)))));
    }

    function _initData(
        ICollateralPolicy.Tier tier
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            FarmentaMarket.initialize, (IERC20(address(usdg)), "Farmenta USDG Blue-chip", "fUSDG-BC", tier, owner)
        );
    }
}
