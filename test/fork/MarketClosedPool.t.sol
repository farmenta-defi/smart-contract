// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {MarketDebt} from "../../src/libraries/MarketDebt.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

/// @notice What a disabled token and a revoked hook do to `borrow` against collateral the market
///         already holds, on a real position (ARCHITECTURE §6.5, FAR-74).
/// @dev Before FAR-74 both closed the way in and left `borrow` open until each pool was frozen.
///      Every test here starts from a position in custody with a loan on it and room to draw
///      more, and none of them freezes the pool.
///
///      That a loan in such a pool can still be repaid, withdrawn and liquidated is held by
///      `MarketGuardianForkTest`, written for FAR-68 and unchanged.
contract MarketClosedPoolForkTest is MarketForkTest {
    /// @dev Well under the fixture's borrow limit, so a second draw of the same size fits.
    uint256 internal constant DRAW = 20e6;

    address internal guardian = address(0x6A4D);
    address internal lender = address(0x1E4DE2);

    uint256 internal tokenId;
    address internal borrower;
    PoolId internal poolId;

    /// @dev The fixture pool's own token. Its pair is native ETH and USDG, not WETH.
    Currency internal eth = Currency.wrap(RobinhoodChain.NATIVE);

    /// @dev Held rather than read through `market.asset()` at the call site: that is an
    ///      external call, and one inside a pranked statement spends the prank.
    IERC20 internal usdg;

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        borrower = nft.ownerOf(tokenId);
        usdg = IERC20(market.asset());
        poolId = _keyOf(tokenId).toId();

        vm.prank(owner);
        policy.setGuardian(guardian);

        _listPoolOf(tokenId, 50e18);
        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(usdg), lender, 300e6);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(300e6, lender);
        vm.stopPrank();

        vm.prank(borrower);
        market.borrow(tokenId, DRAW, borrower);
    }

    /* --------------------------------- tokens --------------------------------- */

    function test_RevertWhenBorrowingAgainstATokenTheGuardianDisabled() public {
        vm.prank(guardian);
        policy.disableToken(eth);

        _expectClosed(tokenId, poolId, borrower);
        assertFalse(policy.listingOf(poolId).frozen, "the pool was frozen, so the freeze is what closed it");
    }

    function test_RevertWhenBorrowingAgainstATokenTheOwnerDisabled() public {
        _setEnabled(eth, false);

        _expectClosed(tokenId, poolId, borrower);
        assertFalse(policy.listingOf(poolId).frozen, "the pool was frozen, so the freeze is what closed it");
    }

    /// @notice The quote is a token of the pool like the other.
    function test_RevertWhenBorrowingWithTheQuoteDisabled() public {
        vm.prank(guardian);
        policy.disableToken(Currency.wrap(RobinhoodChain.USDG));

        _expectClosed(tokenId, poolId, borrower);
    }

    /// @notice The owner enables the token again and the borrower draws, on the listing as it was.
    function test_enablingTheTokenAgainLetsTheBorrowerDrawWithoutListingAgain() public {
        bytes32 listed = keccak256(abi.encode(policy.listingOf(poolId)));
        vm.prank(guardian);
        policy.disableToken(eth);
        _expectClosed(tokenId, poolId, borrower);

        _setEnabled(eth, true);

        _draw(tokenId, borrower);
        assertEq(keccak256(abi.encode(policy.listingOf(poolId))), listed, "the listing changed");
    }

    /// @notice WETH is not a token of the ETH/USDG pool, so disabling it closes nothing here.
    function test_disablingATokenThePoolDoesNotHoldLeavesItLending() public {
        vm.prank(guardian);
        policy.disableToken(Currency.wrap(RobinhoodChain.WETH));

        _draw(tokenId, borrower);
    }

    /// @notice No amount gets through, from the smallest loan to the whole vault, whichever
    ///         token was disabled and whoever disabled it.
    function testFuzz_RevertWhenBorrowingAnyAmountAgainstADisabledToken(
        uint256 amount,
        bool theQuote,
        bool asGuardian
    ) public {
        amount = bound(amount, 1, usdg.balanceOf(address(market)));
        Currency currency = theQuote ? Currency.wrap(RobinhoodChain.USDG) : eth;
        if (asGuardian) {
            vm.prank(guardian);
            policy.disableToken(currency);
        } else {
            _setEnabled(currency, false);
        }

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(MarketDebt.PoolNotOpenForBorrowing.selector, poolId));
        market.borrow(tokenId, amount, borrower);
    }

    /* --------------------------------- helpers -------------------------------- */

    function _expectClosed(
        uint256 id,
        PoolId pool,
        address holder
    ) private {
        uint256 debt = market.debtOf(id);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(MarketDebt.PoolNotOpenForBorrowing.selector, pool));
        market.borrow(id, DRAW, holder);

        assertEq(market.debtOf(id), debt, "a refused borrow moved the debt");
    }

    function _draw(
        uint256 id,
        address holder
    ) private {
        uint256 debt = market.debtOf(id);
        uint256 balance = usdg.balanceOf(holder);

        vm.prank(holder);
        market.borrow(id, DRAW, holder);

        assertEq(market.debtOf(id), debt + DRAW, "the draw did not reach the ledger");
        assertEq(usdg.balanceOf(holder), balance + DRAW, "the draw did not reach the borrower");
    }

    /// @dev The owner's switch, with the tier, decimals and feed the token already has.
    function _setEnabled(
        Currency currency,
        bool enabled
    ) private {
        (, ICollateralPolicy.Tier tier, uint8 decimals, address priceFeed) = policy.tokenConfig(currency);
        vm.prank(owner);
        policy.setTokenConfig(currency, enabled, tier, decimals, priceFeed);
    }
}
