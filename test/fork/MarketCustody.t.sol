// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC721Permit_v4} from "@uniswap/v4-periphery/src/interfaces/IERC721Permit_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ERC721PermitHash} from "@uniswap/v4-periphery/src/libraries/ERC721PermitHash.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {PositionMinter} from "../base/PositionMinter.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice The EIP-712 domain separator, which `IPositionManager` does not expose.
interface IEIP712Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Takes real positions off real owners and into the market.
/// @dev Custody is the one thing that cannot be proved against a mock. These positions belong
///      to strangers, sit in pools with live hooks, and hold native ETH on one side — the
///      shapes a hand-built ERC-721 double would quietly get wrong.
contract MarketCustodyForkTest is PositionMinter {
    /// @dev ETH price implied by the fixture pool's own spot price at the pinned block, so
    ///      oracle and pool agree and the valuation is the one the chain would give.
    uint256 internal constant ETH_AT_POOL_SPOT = 2520.1324440246868e18;
    uint256 internal constant ONE_USD = 1e18;

    address internal owner = address(0xA11CE);

    /// @dev Keys the test can sign with. Fixture positions belong to strangers, so a position
    ///      is handed to `vm.addr(SIGNER_PK)` before any permit is exercised.
    uint256 internal constant SIGNER_PK = 0xA11CE5EED;
    uint256 internal constant IMPOSTOR_PK = 0xBADBEEF;

    /// @dev Mirrors the private constant in `FarmentaMarket`; the unit suite proves it is the
    ///      ERC-7201 slot for `farmenta.storage.Market`.
    bytes32 internal constant MARKET_STORAGE_LOCATION =
        0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;

    MockPriceOracle internal oracle;
    PositionValuer internal valuer;
    CollateralPolicy internal policy;
    FarmentaMarket internal market;
    IERC721 internal nft;

    function setUp() public override {
        super.setUp();

        oracle = new MockPriceOracle();
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), ONE_USD, RobinhoodChain.USDG_DECIMALS);

        valuer = new PositionValuer(positionManager, stateView, oracle);
        policy = new CollateralPolicy(Currency.wrap(RobinhoodChain.USDG), owner);

        vm.startPrank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.USDG), true, ICollateralPolicy.Tier.BLUE_CHIP, 6);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.WETH), true, ICollateralPolicy.Tier.BLUE_CHIP, 18);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.BLUE_CHIP, 18);
        vm.stopPrank();

        market = _deployMarket(ICollateralPolicy.Tier.BLUE_CHIP);
        nft = IERC721(RobinhoodChain.POSITION_MANAGER);
    }

    /* --------------------------------- happy path ----------------------------- */

    /// @notice The market ends up owning the NFT, and remembers who handed it over.
    /// @dev Ownership is the assertion that matters. `PositionManager` gates
    ///      `DECREASE_LIQUIDITY` and `BURN_POSITION` on `onlyIfApproved(msgSender())`, so a
    ///      market that recorded the loan but failed to take the token could never liquidate
    ///      it. Bookkeeping alone is not custody.
    function test_depositTakesCustodyAndRecordsTheDepositor() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);

        // Approve first, then arm the matcher: `approve` emits its own event, and it would
        // otherwise be the log the expectation is compared against.
        vm.startPrank(holder);
        nft.approve(address(market), tokenId);

        vm.expectEmit(true, true, false, false, address(market));
        emit FarmentaMarket.CollateralDeposited(tokenId, holder);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        FarmentaMarket.Loan memory loan = market.loanOf(tokenId);
        assertEq(loan.owner, holder, "depositor not recorded");
        assertEq(loan.debtShares, 0, "a fresh deposit owes nothing");
    }

    /// @dev Native ETH is `address(0)` inside a PoolKey, and this pool also runs a live
    ///      dynamic-fee hook. A policy or valuer that only handled ERC-20 pairs would reject
    ///      most of the chain's ETH liquidity, so the main fixture above is deliberately that
    ///      pool; this asserts the shape it actually has.
    function test_theMainFixtureIsNativeEthBehindALiveHook() public view {
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        assertEq(Currency.unwrap(key.currency0), RobinhoodChain.NATIVE, "expected native ETH as currency0");
        assertEq(address(key.hooks), Fixtures.HOOK_ETH_USDG_DYN, "expected the dyn-fee hook");
    }

    function test_bothErc20SidesAreAccepted() public {
        uint256 tokenId = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);

        _deposit(tokenId, holder);
        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        assertEq(market.loanOf(tokenId).owner, holder, "depositor not recorded");
    }

    /// @notice A position pushed straight here with `safeTransferFrom` lands as a real deposit.
    /// @dev The second intake path runs the same checks, so it cannot be used to slip a
    ///      position past the policy. It exists so a transfer that would otherwise strand an
    ///      NFT in this contract instead records who it belongs to.
    function test_directSafeTransferIsAcceptedTheSameWay() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);

        vm.prank(holder);
        nft.safeTransferFrom(holder, address(market), tokenId);

        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        assertEq(market.loanOf(tokenId).owner, holder, "depositor not recorded");
    }

    /* ---------------------------------- refusals ------------------------------ */

    function test_unlistedPoolIsRefused() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        address holder = nft.ownerOf(tokenId);
        PoolKey memory key = _keyOf(tokenId);

        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolNotListed.selector, key.toId()));
        market.depositCollateral(tokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), holder, "a refused deposit must leave the NFT alone");
    }

    /// @dev Freezing stops new collateral without touching what is already held (§6.5).
    function test_frozenPoolIsRefused() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        PoolKey memory key = _keyOf(tokenId);

        vm.prank(owner);
        policy.setFrozen(key.toId(), true);

        address holder = nft.ownerOf(tokenId);
        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolFrozenForNewPositions.selector, key.toId()));
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    /// @dev The isolation in §1 #8 is only real if each market refuses the other's collateral.
    function test_marketRefusesAnotherTiersPool() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);

        FarmentaMarket memeMarket = _deployMarket(ICollateralPolicy.Tier.MEME);
        address holder = nft.ownerOf(tokenId);

        vm.startPrank(holder);
        nft.approve(address(memeMarket), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralPolicy.WrongTier.selector, ICollateralPolicy.Tier.BLUE_CHIP, ICollateralPolicy.Tier.MEME
            )
        );
        memeMarket.depositCollateral(tokenId);
        vm.stopPrank();
    }

    /// @notice Dust is refused, measured on principal alone.
    /// @dev The fixture is worth roughly $382, so a floor above that must stop it. Listings
    ///      may only tighten the tier preset, which is why the floor is raised rather than
    ///      lowered to build this case.
    function test_positionBelowTheMinimumIsRefused() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 1_000_000e18);
        address holder = nft.ownerOf(tokenId);

        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        vm.expectRevert();
        market.depositCollateral(tokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), holder, "a refused deposit must leave the NFT alone");
    }

    /// @dev Both intake paths stop while paused, or pausing would only close the front door.
    function test_pausingStopsBothIntakePaths() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);

        vm.prank(owner);
        market.pause();

        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        vm.expectRevert();
        market.depositCollateral(tokenId);

        vm.expectRevert();
        nft.safeTransferFrom(holder, address(market), tokenId);
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), holder, "a paused market must not take custody");
    }

    /* --------------------------------- withdraw ------------------------------- */

    function test_withdrawReturnsThePositionToItsDepositor() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        vm.expectEmit(true, true, false, false, address(market));
        emit FarmentaMarket.CollateralWithdrawn(tokenId, holder);
        vm.prank(holder);
        market.withdrawCollateral(tokenId, holder);

        assertEq(nft.ownerOf(tokenId), holder, "position did not go back");
        assertEq(market.loanOf(tokenId).owner, address(0), "the record should be cleared");
    }

    function test_withdrawCanSendSomewhereElse() public {
        uint256 tokenId = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        address elsewhere = address(0xE15E);
        vm.prank(holder);
        market.withdrawCollateral(tokenId, elsewhere);

        assertEq(nft.ownerOf(tokenId), elsewhere, "position went to the wrong address");
    }

    function test_onlyTheDepositorMayWithdraw() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        address thief = address(0xBAD);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotTheDepositor.selector, tokenId, holder));
        market.withdrawCollateral(tokenId, thief);

        assertEq(nft.ownerOf(tokenId), address(market), "the market should still hold it");
    }

    function test_cannotWithdrawSomethingNeverDeposited() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotTheDepositor.selector, uint256(42), address(0)));
        market.withdrawCollateral(42, address(0xBAD));
    }

    /// @notice Pausing must not strand collateral that owes nothing.
    /// @dev The deliberate asymmetry: intake stops while paused, release does not. A position
    ///      with no debt against it belongs entirely to its depositor, so holding it back
    ///      protects nobody and turns an operational lever into a way to trap other people's
    ///      assets. §6.5 reaches the same conclusion for frozen pools.
    function test_withdrawStillWorksWhilePaused() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        vm.prank(owner);
        market.pause();

        vm.prank(holder);
        market.withdrawCollateral(tokenId, holder);
        assertEq(nft.ownerOf(tokenId), holder, "a paused market trapped debt-free collateral");
    }

    /// @dev Proves the record is genuinely cleared rather than just emptied of its owner: a
    ///      leftover entry would make the second deposit revert as already held.
    function test_aWithdrawnPositionCanBeDepositedAgain() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);

        _deposit(tokenId, holder);
        vm.prank(holder);
        market.withdrawCollateral(tokenId, holder);
        _deposit(tokenId, holder);

        assertEq(nft.ownerOf(tokenId), address(market), "second deposit did not take");
        assertEq(market.loanOf(tokenId).owner, holder, "second deposit not recorded");
    }

    /// @notice Debt blocks withdrawal, checked now rather than when the ledger exists.
    /// @dev Nothing writes `debtShares` yet, so the only way to reach this branch is to plant
    ///      a value in the slot the contract reads. That is the point: the gate that stops a
    ///      borrower walking off with their collateral is the last one anybody should
    ///      discover is missing, and it is verified before there is any borrowing at all.
    function test_outstandingDebtBlocksWithdrawal() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        vm.store(address(market), _debtSharesSlot(tokenId), bytes32(uint256(1e18)));
        assertEq(market.loanOf(tokenId).debtShares, 1e18, "the planted debt is not where the market reads");

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.OutstandingDebt.selector, tokenId, uint256(1e18)));
        market.withdrawCollateral(tokenId, holder);
    }

    /// @dev Sending the position to the market itself would re-enter the intake callback and
    ///      re-record what was just released.
    function test_withdrawRefusesDegenerateRecipients() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, address(0)));
        market.withdrawCollateral(tokenId, address(0));

        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, address(market)));
        market.withdrawCollateral(tokenId, address(market));
        vm.stopPrank();
    }

    /// @notice A position drained to zero liquidity is refused.
    /// @dev §6.1 rejects empty positions, and this shows the case is real rather than
    ///      theoretical: decreasing a position to zero leaves the NFT alive, transferable and
    ///      holding nothing at all. Accepting one would record collateral worth zero, which is
    ///      a loan against nothing the moment borrowing exists.
    function test_drainedPositionIsRefused() public {
        PoolKey memory key = _keyOf(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);
        int24 spacing = key.tickSpacing;
        int24 mid = _alignedOracleTick(spacing);

        _fundAndApprove(key, 10 ether, 100_000e6);
        uint256 tokenId = _mint(key, mid - 10 * spacing, mid + 10 * spacing, 1e15);
        _drain(key, tokenId, 1e15);

        assertEq(positionManager.getPositionLiquidity(tokenId), 0, "the position should be empty");
        assertEq(nft.ownerOf(tokenId), address(this), "an emptied position keeps its NFT");

        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);

        nft.approve(address(market), tokenId);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PositionIsEmpty.selector, tokenId));
        market.depositCollateral(tokenId);
    }

    /// @notice A hook that skims on withdrawal shrinks the value the floor is measured against.
    /// @dev §6.3 records `removeHaircutBps` at listing and deducts it from the value. What
    ///      backs a loan is what the protocol could actually pull back out, not what the
    ///      position reads as on paper. Same position and same floor as the test below, which
    ///      passes; only the haircut differs.
    function test_removeHaircutIsDeductedBeforeTheMinimum() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 300e18, 5000);

        uint256 principal = valuer.value(tokenId).principalUsd;
        assertGt(principal, 300e18, "the fixture must clear the floor before any haircut");

        address holder = nft.ownerOf(tokenId);
        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, principal / 2, uint256(300e18))
        );
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    /// @dev The control for the test above: without the haircut the same position clears the
    ///      same floor, so the refusal there is the deduction and nothing else.
    function test_theSameFloorPassesWithoutAHaircut() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 300e18, 0);
        address holder = nft.ownerOf(tokenId);

        _deposit(tokenId, holder);
        assertEq(nft.ownerOf(tokenId), address(market), "the position should have been accepted");
    }

    /* ---------------------------------- rescue -------------------------------- */

    /// @notice A position that arrived without the callback can be swept back out.
    /// @dev A plain `transferFrom` is not a `safeTransferFrom`, so nothing tells this contract
    ///      it happened. The same silence applies to a position minted straight to this
    ///      address, because `PositionManager` mints with solmate's `_mint` and fires no
    ///      callback at all. Either way the NFT sits here belonging to nobody the market can
    ///      name, and only this can retrieve it.
    function test_rescueReturnsAPositionThatArrivedUnrecorded() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        address holder = nft.ownerOf(tokenId);

        vm.prank(holder);
        nft.transferFrom(holder, address(market), tokenId);

        assertEq(nft.ownerOf(tokenId), address(market), "the market should be holding it");
        assertEq(market.loanOf(tokenId).owner, address(0), "an unsafe transfer must record nothing");

        vm.prank(owner);
        market.rescueUnaccountedToken(tokenId, holder);
        assertEq(nft.ownerOf(tokenId), holder, "rescue did not return the position");
    }

    /// @notice Rescue can never be turned on collateral somebody actually deposited.
    /// @dev The guard that keeps this from being a back door into every borrower's position.
    function test_rescueCannotTouchRecordedCollateral() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PositionIsCollateral.selector, tokenId));
        market.rescueUnaccountedToken(tokenId, owner);

        assertEq(nft.ownerOf(tokenId), address(market), "collateral must stay put");
    }

    function test_onlyTheOwnerMayRescue() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        address holder = nft.ownerOf(tokenId);
        vm.prank(holder);
        nft.transferFrom(holder, address(market), tokenId);

        address thief = address(0xBAD);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, thief));
        market.rescueUnaccountedToken(tokenId, thief);
    }

    /* ---------------------------------- permit -------------------------------- */

    /// @notice One transaction instead of two: the owner signs, and the position moves.
    function test_permitDepositsWithoutASeparateApproval() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address signer = _giveToSigner(tokenId);

        assertEq(nft.getApproved(tokenId), address(0), "no approval should exist yet");

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signPermit(SIGNER_PK, tokenId, 0, deadline);

        vm.prank(signer);
        market.depositCollateralWithPermit(tokenId, deadline, 0, signature);

        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        assertEq(market.loanOf(tokenId).owner, signer, "depositor not recorded");
    }

    /// @notice A signature built over the usual four-field EIP-712 domain is rejected.
    /// @dev The trap this whole function exists to document. ERC-721 has no permit, and
    ///      Uniswap's own domain carries name, chainId and verifyingContract but **no
    ///      version**. Every wallet helper and most examples add one, and the resulting
    ///      signature fails with nothing to indicate why. Pinning that here means a future
    ///      change to the domain surfaces as this test breaking.
    function test_permitSignedWithAVersionedDomainIsRejected() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address signer = _giveToSigner(tokenId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 versionedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Uniswap v4 Positions NFT")),
                keccak256(bytes("1")),
                block.chainid,
                RobinhoodChain.POSITION_MANAGER
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901", versionedDomain, ERC721PermitHash.hashPermit(address(market), tokenId, 0, deadline)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PermitRejected.selector, tokenId));
        market.depositCollateralWithPermit(tokenId, deadline, 0, abi.encodePacked(r, s, v));
    }

    function test_permitFromTheWrongSignerIsRejected() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address signer = _giveToSigner(tokenId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signPermit(IMPOSTOR_PK, tokenId, 0, deadline);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PermitRejected.selector, tokenId));
        market.depositCollateralWithPermit(tokenId, deadline, 0, signature);
    }

    function test_expiredPermitIsRejected() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address signer = _giveToSigner(tokenId);

        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _signPermit(SIGNER_PK, tokenId, 0, deadline);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PermitRejected.selector, tokenId));
        market.depositCollateralWithPermit(tokenId, deadline, 0, signature);
    }

    /// @notice A permit spent by someone else first still leaves the deposit working.
    /// @dev Permits are public once broadcast and `PositionManager.permit` is callable by
    ///      anyone, so a bystander can spend the nonce before this transaction lands. Without
    ///      the catch that would revert a deposit whose approval had in fact been granted,
    ///      which is a free way to grief every permit deposit.
    function test_aPermitAlreadySpentBySomeoneElseStillDeposits() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address signer = _giveToSigner(tokenId);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signPermit(SIGNER_PK, tokenId, 0, deadline);

        // A bystander front-runs, spending the nonce but leaving the approval in place.
        vm.prank(address(0xF00D));
        IERC721Permit_v4(RobinhoodChain.POSITION_MANAGER).permit(address(market), tokenId, deadline, 0, signature);
        assertEq(nft.getApproved(tokenId), address(market), "the front-run permit should have approved us");

        vm.prank(signer);
        market.depositCollateralWithPermit(tokenId, deadline, 0, signature);

        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        assertEq(market.loanOf(tokenId).owner, signer, "depositor not recorded");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev Where `loans[tokenId].debtShares` lives. `MarketStorage` puts `tier` at the
    ///      namespace root and the `loans` mapping one slot on; inside `Loan`, `owner` comes
    ///      first and `debtShares` second. Derived rather than hard-coded so a change to the
    ///      layout shows up as a failing assertion instead of a silently harmless write.
    function _debtSharesSlot(
        uint256 tokenId
    ) internal pure returns (bytes32) {
        uint256 loansSlot = uint256(MARKET_STORAGE_LOCATION) + 1;
        return bytes32(uint256(keccak256(abi.encode(tokenId, loansSlot))) + 1);
    }

    /// @dev Fixture positions belong to strangers whose keys nobody has, so a position is
    ///      moved to an address this test can sign for before any permit is exercised.
    function _giveToSigner(
        uint256 tokenId
    ) internal returns (address signer) {
        signer = vm.addr(SIGNER_PK);
        address holder = nft.ownerOf(tokenId);
        vm.prank(holder);
        nft.transferFrom(holder, signer, tokenId);
    }

    /// @dev Struct hash comes from Uniswap's own library so it cannot drift from the
    ///      contract. The domain is read live from `PositionManager` for the same reason.
    function _signPermit(
        uint256 privateKey,
        uint256 tokenId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                IEIP712Domain(RobinhoodChain.POSITION_MANAGER).DOMAIN_SEPARATOR(),
                ERC721PermitHash.hashPermit(address(market), tokenId, nonce, deadline)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _deposit(
        uint256 tokenId,
        address holder
    ) internal {
        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    function _keyOf(
        uint256 tokenId
    ) internal view returns (PoolKey memory key) {
        (key,) = positionManager.getPoolAndPositionInfo(tokenId);
    }

    /// @dev The key is read before `vm.prank`, not inside the call. `getPoolAndPositionInfo`
    ///      is an external call, so evaluating it as an argument would spend the prank and
    ///      leave `list` to be called by this test contract, which is not the owner.
    /// @dev Empties a position without burning it, which is the only way to reach a live NFT
    ///      that holds nothing.
    function _drain(
        PoolKey memory key,
        uint256 tokenId,
        uint256 liquidity
    ) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    /// @dev The tick the oracle implies, snapped down onto the pool's spacing. Ranges are
    ///      placed against this rather than the pool's own tick because the valuer decides
    ///      in or out of range at the oracle price (§5.1).
    function _alignedOracleTick(
        int24 spacing
    ) internal pure returns (int24) {
        int24 tick = TickMath.getTickAtSqrtPrice(
            PriceMath.derivedSqrtPriceX96(ETH_AT_POOL_SPOT, ONE_USD, 18, RobinhoodChain.USDG_DECIMALS)
        );
        // Dividing before multiplying is the point: it snaps the tick down onto the spacing.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
        return aligned;
    }

    function _listPoolOf(
        uint256 tokenId,
        uint128 minPositionUsd
    ) internal {
        _listPoolOf(tokenId, minPositionUsd, 0);
    }

    function _listPoolOf(
        uint256 tokenId,
        uint128 minPositionUsd,
        uint16 removeHaircutBps
    ) internal {
        PoolKey memory key = _keyOf(tokenId);
        TierPresets.Preset memory preset = TierPresets.blueChip();

        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: removeHaircutBps,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: minPositionUsd
            })
        );
    }

    function _deployMarket(
        ICollateralPolicy.Tier tier_
    ) internal returns (FarmentaMarket) {
        FarmentaMarket implementation = new FarmentaMarket(positionManager, policy, valuer);
        return FarmentaMarket(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            FarmentaMarket.initialize,
                            (IERC20(RobinhoodChain.USDG), "Farmenta USDG", "fUSDG", tier_, owner)
                        )
                    )
                ))
        );
    }
}
