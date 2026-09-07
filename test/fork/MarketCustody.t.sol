// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice Takes real positions off real owners and into the market.
/// @dev Custody is the one thing that cannot be proved against a mock. These positions belong
///      to strangers, sit in pools with live hooks, and hold native ETH on one side — the
///      shapes a hand-built ERC-721 double would quietly get wrong.
contract MarketCustodyForkTest is ForkTest {
    /// @dev ETH price implied by the fixture pool's own spot price at the pinned block, so
    ///      oracle and pool agree and the valuation is the one the chain would give.
    uint256 internal constant ETH_AT_POOL_SPOT = 2520.1324440246868e18;
    uint256 internal constant ONE_USD = 1e18;

    address internal owner = address(0xA11CE);

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

    /* --------------------------------- helpers -------------------------------- */

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
    function _listPoolOf(
        uint256 tokenId,
        uint128 minPositionUsd
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
                removeHaircutBps: 0,
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
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        FarmentaMarket.initialize, (IERC20(RobinhoodChain.USDG), "Farmenta USDG", "fUSDG", tier_, owner)
                    )
                )
            )
        );
    }
}
