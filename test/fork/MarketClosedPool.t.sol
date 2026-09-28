// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

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
    address internal recipient = makeAddr("recipient");

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

    /* ---------------------------------- hooks --------------------------------- */

    function test_RevertWhenBorrowingBehindAHookTheGuardianRevoked() public {
        (uint256 hooked, PoolId hookedPool) = _openBehindAllowlistedHook();

        vm.prank(guardian);
        policy.revokeHook(REMOVAL_HAIRCUT_HOOK);

        _expectClosed(hooked, hookedPool, address(this));
        assertFalse(policy.listingOf(hookedPool).frozen, "the pool was frozen, so the freeze is what closed it");
    }

    function test_RevertWhenBorrowingBehindAHookTheOwnerRevoked() public {
        (uint256 hooked, PoolId hookedPool) = _openBehindAllowlistedHook();

        vm.prank(owner);
        policy.setHookAllowlist(REMOVAL_HAIRCUT_HOOK, false);

        _expectClosed(hooked, hookedPool, address(this));
    }

    /// @notice The fixture pool's hook is swap-only and passes the bit check, so it never needed
    ///         the allowlist and a revoke stops nothing. `checkPool` answers the same.
    function test_revokingAHookThatPassesTheBitCheckDoesNotStopBorrowing() public {
        PoolKey memory key = _keyOf(tokenId);
        assertEq(address(key.hooks), Fixtures.HOOK_ETH_USDG_DYN, "the fixture pool changed its hook");

        vm.prank(guardian);
        policy.revokeHook(Fixtures.HOOK_ETH_USDG_DYN);

        _draw(tokenId, borrower);
        policy.checkPool(key, ICollateralPolicy.Tier.BLUE_CHIP);
    }

    /// @notice A revoke reaches the pools behind that hook and no other.
    function test_aRevokedHookLeavesAPoolBehindAnotherHookLending() public {
        _openBehindAllowlistedHook();

        vm.prank(guardian);
        policy.revokeHook(REMOVAL_HAIRCUT_HOOK);

        _draw(tokenId, borrower);
    }

    function test_allowlistingTheHookAgainLetsTheBorrowerDrawWithoutListingAgain() public {
        (uint256 hooked, PoolId hookedPool) = _openBehindAllowlistedHook();
        vm.prank(guardian);
        policy.revokeHook(REMOVAL_HAIRCUT_HOOK);
        _expectClosed(hooked, hookedPool, address(this));

        vm.prank(owner);
        policy.setHookAllowlist(REMOVAL_HAIRCUT_HOOK, true);

        _draw(hooked, address(this));
    }

    /* ----------------------------- what stays open ---------------------------- */

    /// @notice Fees are the borrower's, and a disabled token does not hold them back.
    function test_feesAreCollectedFromAPoolOfADisabledToken() public {
        uint256 fees0 = valuer.value(tokenId).fees0;
        uint256 fees1 = valuer.value(tokenId).fees1;
        assertGt(fees0, 0, "the fixture must hold ETH fees");
        assertGt(fees1, 0, "the fixture must hold USDG fees");
        vm.prank(guardian);
        policy.disableToken(eth);

        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(recipient.balance, fees0, "the ETH fees reach the recipient");
        assertEq(usdg.balanceOf(recipient), fees1, "the USDG fees reach the recipient");
    }

    /// @notice Liquidity leaves a pool of a disabled token as it would any other, while the loan
    ///         stays within its limit.
    function test_liquidityIsRemovedFromAPoolOfADisabledToken() public {
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        uint128 slice = liquidity / 10;
        uint256 debt = market.debtOf(tokenId);
        vm.prank(guardian);
        policy.disableToken(eth);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, slice, 0, 0, recipient);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - slice, "the slice did not leave");
        assertGt(recipient.balance, 0, "the ETH leg did not reach the recipient");
        assertGt(usdg.balanceOf(recipient), 0, "the USDG leg did not reach the recipient");
        assertEq(market.debtOf(tokenId), debt, "the removal moved the debt");
    }

    /// @notice The same behind a revoked hook.
    function test_liquidityIsRemovedFromAPoolBehindARevokedHook() public {
        (uint256 hooked,) = _openBehindAllowlistedHook();
        uint128 liquidity = positionManager.getPositionLiquidity(hooked);
        uint128 slice = liquidity / 10;
        vm.prank(guardian);
        policy.revokeHook(REMOVAL_HAIRCUT_HOOK);

        market.decreaseLiquidity(hooked, slice, 0, 0, recipient);

        assertEq(positionManager.getPositionLiquidity(hooked), liquidity - slice, "the slice did not leave");
    }

    /// @notice Terms and prices stay readable, since the loans that exist are judged by them.
    function test_termsAndHealthStayReadableInAPoolOfADisabledToken() public {
        bytes32 terms = keccak256(abi.encode(policy.termsOf(poolId)));
        uint256 healthFactor = lens.healthFactor(tokenId);

        vm.prank(guardian);
        policy.disableToken(eth);

        assertEq(keccak256(abi.encode(policy.termsOf(poolId))), terms, "the terms changed");
        assertEq(lens.healthFactor(tokenId), healthFactor, "the health factor moved");
    }

    /* ----------------------------------- gas ---------------------------------- */

    /// @notice What the token and hook reads cost `borrow` (FAR-74).
    /// @dev Storage is cooled first, so the figure is what a transaction pays and not what a
    ///      test that has already touched the policy pays. Measured on the pinned block with
    ///      this test, against the policy before FAR-74 and after: `acceptsNewPositions` 7,773
    ///      and 18,698, `borrow` 184,155 and 195,080. Both rise by 10,925, which is five cold
    ///      storage reads: the three slots of the recorded key and the two token records. A
    ///      hook that needs the allowlist adds a sixth.
    ///
    ///      The ceilings are loose on purpose, as in `TwapRecorderForkTest`: they catch a read
    ///      that multiplies, not a toolchain that counts differently.
    function test_theTokenAndHookReadsCostBorrowAFewStorageSlots() public {
        vm.cool(address(policy));
        uint256 gasBefore = gasleft();
        policy.acceptsNewPositions(poolId);
        uint256 viewGas = gasBefore - gasleft();

        _coolEverythingBorrowTouches();
        vm.prank(borrower);
        gasBefore = gasleft();
        market.borrow(tokenId, DRAW, borrower);
        uint256 borrowGas = gasBefore - gasleft();

        emit log_named_uint("acceptsNewPositions gas", viewGas);
        emit log_named_uint("borrow gas", borrowGas);
        assertLt(viewGas, 2 * 18_698, "acceptsNewPositions exceeded its loose ceiling");
        assertLt(borrowGas, 2 * 195_080, "borrow exceeded its loose ceiling");
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

    /// @dev A second position, minted behind a hook that only the allowlist admits, with a loan
    ///      on it and room to draw more. This test contract is its borrower.
    function _openBehindAllowlistedHook() private returns (uint256 hooked, PoolId hookedPool) {
        hooked = _mintRemovalHaircutPosition(0, 1e14);
        PoolKey memory hookedKey = _keyOf(hooked);
        hookedPool = hookedKey.toId();
        _listPool(hookedKey, 50e18, 0);

        IERC721(RobinhoodChain.POSITION_MANAGER).approve(address(market), hooked);
        market.depositCollateral(hooked);
        assertGt(lens.maxBorrow(hooked), 2 * DRAW, "the minted position is too small for two draws");
        market.borrow(hooked, DRAW, address(this));
    }

    function _coolEverythingBorrowTouches() private {
        vm.cool(address(policy));
        vm.cool(address(market));
        vm.cool(address(valuer));
        vm.cool(address(oracle));
        vm.cool(address(interestRateModel));
        vm.cool(address(stateView));
        vm.cool(address(poolManager));
        vm.cool(address(positionManager));
        vm.cool(RobinhoodChain.USDG);
    }
}
