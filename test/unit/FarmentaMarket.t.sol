// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {MarketLens} from "../../src/MarketLens.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
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
    address internal oracle = address(0x0A11CE);
    InterestRateModel internal rateModel;
    address internal interestRateModel;

    MockERC20 internal usdg;
    FarmentaMarket internal implementation;
    FarmentaMarket internal market;
    MarketLens internal lens;

    function setUp() public {
        usdg = new MockERC20("Paxos USDG", "USDG", RobinhoodChain.USDG_DECIMALS);
        rateModel = new InterestRateModel();
        interestRateModel = address(rateModel);
        implementation = _deployImplementation();
        market = _deployProxy(ICollateralPolicy.Tier.BLUE_CHIP);
        lens = new MarketLens(market);
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

    function test_oneImplementationServesBothTierCurves() public {
        FarmentaMarket memeMarket = _deployProxy(ICollateralPolicy.Tier.MEME);
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

        assertEq(vm.load(address(market), implementationSlot), vm.load(address(memeMarket), implementationSlot));
        assertEq(
            vm.load(address(market), implementationSlot),
            bytes32(uint256(uint160(address(implementation)))),
            "proxies must share one market implementation"
        );
        assertApproxEqAbs(
            rateModel.ratePerSecond(market.tier(), 70e16) * 365 days,
            35e15,
            1e8,
            "blue-chip market should use its 3.5% curve point"
        );
        assertApproxEqAbs(
            rateModel.ratePerSecond(memeMarket.tier(), 70e16) * 365 days,
            8e16,
            1e8,
            "meme market should use its 8% curve point"
        );
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
        new FarmentaMarket(
            IPositionManager(payable(address(0))),
            ICollateralPolicy(policy),
            IPositionValuer(valuer),
            IPriceOracle(oracle),
            IInterestRateModel(interestRateModel)
        );

        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(
            IPositionManager(payable(posm)),
            ICollateralPolicy(address(0)),
            IPositionValuer(valuer),
            IPriceOracle(oracle),
            IInterestRateModel(interestRateModel)
        );

        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(
            IPositionManager(payable(posm)),
            ICollateralPolicy(policy),
            IPositionValuer(address(0)),
            IPriceOracle(oracle),
            IInterestRateModel(interestRateModel)
        );

        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(
            IPositionManager(payable(posm)),
            ICollateralPolicy(policy),
            IPositionValuer(valuer),
            IPriceOracle(address(0)),
            IInterestRateModel(interestRateModel)
        );

        vm.expectRevert(FarmentaMarket.ZeroAddress.selector);
        new FarmentaMarket(
            IPositionManager(payable(posm)),
            ICollateralPolicy(policy),
            IPositionValuer(valuer),
            IPriceOracle(oracle),
            IInterestRateModel(address(0))
        );
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

    /* ----------------------------- reserve withdrawal ---------------------------- */

    function test_withdrawReservesLeavesTheTotalAssetsFloorUntouched() public {
        address treasury = address(0x7EA5);
        usdg.mint(address(market), 1_000_000e6);
        _setReserves(market, 20_000e6);

        // Assets are 980,000 USDG after reserves, so the blue-chip floor is 9,800 USDG.
        assertEq(lens.withdrawableReserves(), 10_200e6, "surplus above the total-assets floor");
        uint256 sharePriceBefore = market.convertToAssets(1e18);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(market));
        emit FarmentaMarket.ReservesUpdated(9800e6);
        vm.expectEmit(true, false, false, true, address(market));
        emit FarmentaMarket.ReservesWithdrawn(10_200e6, treasury);
        market.withdrawReserves(10_200e6, treasury);

        assertEq(usdg.balanceOf(treasury), 10_200e6, "treasury did not receive the surplus");
        assertEq(market.reserves(), 9800e6, "reserve floor was not retained");
        assertEq(market.totalReservesWithdrawn(), 10_200e6, "withdrawal history was not recorded");
        assertEq(market.totalAssets(), 980_000e6, "reserve transfer changed lender assets");
        assertEq(market.convertToAssets(1e18), sharePriceBefore, "reserve transfer changed share price");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.ReserveWithdrawalExceedsAvailable.selector, 1, 0));
        market.withdrawReserves(1, treasury);
    }

    function test_withdrawReservesIsLimitedByCash() public {
        address treasury = address(0x7EA5);
        address lender = address(0x1E4DE2);
        usdg.mint(lender, 8000e6);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(8000e6, lender);
        vm.stopPrank();
        _setTotalBorrows(market, 100_000e6);
        _setReserves(market, 30_000e6);

        // Reserve surplus is 29,220 USDG, but only 8,000 USDG exists as cash.
        assertEq(lens.withdrawableReserves(), 8000e6, "cash cap was not applied");

        vm.prank(owner);
        market.withdrawReserves(8000e6, treasury);

        assertEq(usdg.balanceOf(treasury), 8000e6, "cash-limited amount was not transferred");
        assertEq(market.reserves(), 22_000e6, "only withdrawn reserve should decrease");
        assertEq(market.maxWithdraw(lender), 0, "cash cap should close lender withdrawals");
        assertEq(market.totalAssets(), 78_000e6, "cash withdrawal changed lender value");
    }

    function test_withdrawReservesClosesBelowTheFloorAndReopensAfterReplenishment() public {
        address treasury = address(0x7EA5);
        usdg.mint(address(market), 1_000_000e6);
        _setReserves(market, 9000e6);

        assertEq(lens.reserveFloor(), 9910e6, "floor should track lender assets");
        assertEq(lens.withdrawableReserves(), 0, "underfilled reserve must stay locked");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.ReserveWithdrawalExceedsAvailable.selector, 1, 0));
        market.withdrawReserves(1, treasury);

        _setReserves(market, 20_000e6);
        assertEq(lens.withdrawableReserves(), 10_200e6, "replenishment should reopen withdrawal automatically");
    }

    function test_depositRaisesFloorAndReducesWithdrawableReserves() public {
        address lender = address(0x1E4DE2);
        usdg.mint(address(market), 1_000_000e6);
        _setReserves(market, 20_000e6);
        uint256 withdrawableBefore = lens.withdrawableReserves();

        usdg.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(100_000e6, lender);
        vm.stopPrank();

        assertEq(market.totalAssets(), 1_080_000e6, "deposit did not raise total assets");
        assertEq(lens.withdrawableReserves(), withdrawableBefore - 1000e6, "floor did not rise with lender assets");
    }

    function test_withdrawReservesAccruesBeforeCalculatingAvailability() public {
        usdg.mint(address(market), 100_000e6);
        _setTotalBorrowShares(market, 100_000e6);
        _setTotalBorrows(market, 100_000e6);
        _setReserves(market, 10_000e6);
        uint256 withdrawableBefore = lens.withdrawableReserves();
        vm.warp(block.timestamp + 1 days);

        vm.prank(owner);
        market.withdrawReserves(withdrawableBefore + 1, address(0x7EA5));

        assertEq(market.totalReservesWithdrawn(), withdrawableBefore + 1, "withdrawal amount was not recorded");
        assertGe(market.reserves(), lens.reserveFloor(), "withdrawal crossed the accrued floor");
    }

    function test_withdrawReservesUsesTheMemeFloor() public {
        FarmentaMarket memeMarket = _deployProxy(ICollateralPolicy.Tier.MEME);
        usdg.mint(address(memeMarket), 1_000_000e6);
        _setReserves(memeMarket, 30_000e6);

        // 2.5% of 970,000 USDG is 24,250 USDG, leaving 5,750 USDG withdrawable.
        assertEq(new MarketLens(memeMarket).withdrawableReserves(), 5750e6, "meme floor is not 2.5%");
    }

    function test_onlyOwnerCanWithdrawReserves() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        market.withdrawReserves(0, stranger);
    }

    function test_withdrawReservesRejectsInvalidRecipient() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, address(0)));
        market.withdrawReserves(0, address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, address(market)));
        market.withdrawReserves(0, address(market));
    }

    /* ----------------------------- mint and deposit --------------------------- */

    /// @notice ETH sent along with an ERC-20 pair is refused before anything moves.
    /// @dev Nothing in that mint would spend it, and ETH that reaches this market has no way
    ///      back out (§15 no. 12). Refusing it is the only way it is not lost.
    function test_mintAndDepositRefusesEthForAnErc20Pair() public {
        FarmentaMarket.MintParams memory p = _mintParams(_erc20Pair());

        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NativeValueMismatch.selector, 0, 1));
        market.mintAndDeposit{value: 1}(p, _permit(_tokens(RobinhoodChain.WETH, RobinhoodChain.USDG)), "");
    }

    /// @notice A native-ETH mint must send exactly its ETH maximum, no more and no less.
    /// @dev `amount0Max` is the one number the caller gives for the ETH leg. Letting
    ///      `msg.value` differ from it would give that leg two maxima, and a short one would
    ///      only fail later, inside the settle, with nothing to say why.
    function test_mintAndDepositNeedsExactlyAmount0MaxInEth() public {
        FarmentaMarket.MintParams memory p = _mintParams(_nativePair());
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(_tokens(RobinhoodChain.USDG));
        uint256 max0 = p.amount0Max;

        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NativeValueMismatch.selector, max0, max0 - 1));
        market.mintAndDeposit{value: max0 - 1}(p, permit, "");

        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NativeValueMismatch.selector, max0, max0 + 1));
        market.mintAndDeposit{value: max0 + 1}(p, permit, "");
    }

    /// @notice A permit for any token other than the pool's is refused.
    /// @dev The check that keeps lenders' USDG out of a mint. Permit2 moves the token the
    ///      signature names, not the one the market expects, while the settle still pays in
    ///      the pool's currency — so a permit for a worthless token would otherwise be spent
    ///      and the position paid for out of the market's own balance.
    function test_mintAndDepositRefusesAPermitForAnotherToken() public {
        FarmentaMarket.MintParams memory p = _mintParams(_erc20Pair());

        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.mintAndDeposit(p, _permit(_tokens(RobinhoodChain.WETH, address(usdg))), "");
    }

    /// @dev Order is part of the match: each entry pays for the leg at the same place.
    function test_mintAndDepositRefusesAPermitInTheWrongOrder() public {
        FarmentaMarket.MintParams memory p = _mintParams(_erc20Pair());

        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.mintAndDeposit(p, _permit(_tokens(RobinhoodChain.USDG, RobinhoodChain.WETH)), "");
    }

    /// @notice A permit must cover exactly the ERC-20 legs: two for a pair, one beside ETH.
    function test_mintAndDepositRefusesAPermitWithTheWrongLegs() public {
        FarmentaMarket.MintParams memory erc20 = _mintParams(_erc20Pair());
        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.mintAndDeposit(erc20, _permit(_tokens(RobinhoodChain.USDG)), "");

        // ETH is `msg.value`, never a Permit2 transfer, so a permit that lists it is malformed.
        FarmentaMarket.MintParams memory native = _mintParams(_nativePair());
        uint256 max0 = native.amount0Max;
        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.mintAndDeposit{value: max0}(native, _permit(_tokens(RobinhoodChain.NATIVE, RobinhoodChain.USDG)), "");
    }

    /// @dev Minting takes on new risk just as a deposit does, so pausing stops it too.
    function test_mintAndDepositStopsWhilePaused() public {
        vm.prank(owner);
        market.pause();

        FarmentaMarket.MintParams memory p = _mintParams(_erc20Pair());
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        market.mintAndDeposit(p, _permit(_tokens(RobinhoodChain.WETH, RobinhoodChain.USDG)), "");
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

    function test_healthFactorForDebtFreePositionIsUnlimited() public view {
        assertEq(lens.healthFactor(12_345), type(uint256).max);
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev WETH sorts below USDG, so it is currency0.
    function _erc20Pair() internal pure returns (PoolKey memory) {
        return _pool(RobinhoodChain.WETH, RobinhoodChain.USDG);
    }

    /// @dev Native ETH is `address(0)`, which always sorts first.
    function _nativePair() internal pure returns (PoolKey memory) {
        return _pool(RobinhoodChain.NATIVE, RobinhoodChain.USDG);
    }

    function _pool(
        address currency0,
        address currency1
    ) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _mintParams(
        PoolKey memory key
    ) internal pure returns (FarmentaMarket.MintParams memory) {
        return FarmentaMarket.MintParams({
            poolKey: key,
            tickLower: -600,
            tickUpper: 600,
            liquidity: 1e18,
            amount0Max: 1 ether,
            amount1Max: 1000e6,
            hookData: ""
        });
    }

    function _permit(
        address[] memory tokens
    ) internal pure returns (ISignatureTransfer.PermitBatchTransferFrom memory permit) {
        permit.permitted = new ISignatureTransfer.TokenPermissions[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            permit.permitted[i] = ISignatureTransfer.TokenPermissions({token: tokens[i], amount: type(uint256).max});
        }
        permit.deadline = type(uint256).max;
    }

    function _tokens(
        address a
    ) internal pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = a;
    }

    function _tokens(
        address a,
        address b
    ) internal pure returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = a;
        tokens[1] = b;
    }

    function _marketStorageLocation() internal pure returns (bytes32) {
        return 0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;
    }

    function _setTotalBorrows(
        FarmentaMarket target,
        uint256 amount
    ) internal {
        vm.store(address(target), bytes32(uint256(_marketStorageLocation()) + 4), bytes32(amount));
    }

    function _setTotalBorrowShares(
        FarmentaMarket target,
        uint256 amount
    ) internal {
        vm.store(address(target), bytes32(uint256(_marketStorageLocation()) + 3), bytes32(amount));
    }

    function _setReserves(
        FarmentaMarket target,
        uint256 amount
    ) internal {
        vm.store(address(target), bytes32(uint256(_marketStorageLocation()) + 7), bytes32(amount));
    }

    function _deployImplementation() internal returns (FarmentaMarket) {
        return new FarmentaMarket(
            IPositionManager(payable(posm)),
            ICollateralPolicy(policy),
            IPositionValuer(valuer),
            IPriceOracle(oracle),
            IInterestRateModel(interestRateModel)
        );
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
