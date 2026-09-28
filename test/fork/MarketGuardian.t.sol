// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {MarketDebt} from "../../src/libraries/MarketDebt.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

/// @notice What a guardian's action does to a loan that already exists, against a real
///         position: nothing (ARCHITECTURE §6.5, FAR-68).
/// @dev The guardian may stop new risk at once. The other half of that sentence is the claim
///      tested here: a borrower who was already in can still repay and leave, and a position
///      that goes under water can still be liquidated. `pause` is the exception, and
///      `MarketLiquidateForkTest.test_pausingStopsLiquidation` holds it.
contract MarketGuardianForkTest is MarketForkTest {
    address internal guardian = address(0x6A4D);
    address internal lender = address(0x1E4DE2);
    address internal liquidator = address(0x11D);

    uint256 internal tokenId;
    address internal borrower;
    PoolKey internal key;
    PoolId internal poolId;

    /// @dev Held rather than read through `market.asset()` at the call site: that is an
    ///      external call, and one inside a pranked statement spends the prank.
    IERC20 internal usdg;

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        borrower = nft.ownerOf(tokenId);
        usdg = IERC20(market.asset());
        key = _keyOf(tokenId);
        poolId = key.toId();

        vm.startPrank(owner);
        policy.setGuardian(guardian);
        market.setGuardian(guardian);
        vm.stopPrank();

        _open();
    }

    /* --------------------------------- freeze --------------------------------- */

    /// @notice The borrower of a pool the guardian froze repays in full and takes the position
    ///         home.
    function test_aLoanInAPoolTheGuardianFrozeCanBeRepaidAndWithdrawn() public {
        vm.prank(guardian);
        policy.freeze(poolId);

        _repayInFull();

        vm.prank(borrower);
        market.withdrawCollateral(tokenId, borrower);
        assertEq(nft.ownerOf(tokenId), borrower, "the position did not come home");
    }

    /// @notice A position in a pool the guardian froze is liquidated like any other.
    function test_aLoanInAPoolTheGuardianFrozeCanBeLiquidated() public {
        _ageUntilUnderWater();
        vm.prank(guardian);
        policy.freeze(poolId);

        uint256 debt = market.debtOf(tokenId);
        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "a pool the guardian froze must still be liquidatable");
        assertApproxEqAbs(market.debtOf(tokenId), debt - repaid, 1, "the repayment did not reach the ledger");
    }

    /// @notice What the freeze does stop, from the guardian's key: a second loan against the
    ///         collateral already held, and a new position in the pool.
    function test_aGuardianFreezeStopsNewBorrowingAndNewCollateral() public {
        _repayInFull();
        vm.prank(guardian);
        policy.freeze(poolId);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(MarketDebt.PoolNotOpenForBorrowing.selector, poolId));
        market.borrow(tokenId, 1e6, borrower);

        vm.startPrank(borrower);
        market.withdrawCollateral(tokenId, borrower);
        nft.approve(address(market), tokenId);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolFrozenForNewPositions.selector, poolId));
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    /* ------------------------------ disableToken ------------------------------ */

    /// @notice Disabling a token of the pool leaves the loan repayable and the position free to
    ///         leave, and turns a new deposit away.
    function test_aLoanOnADisabledTokenCanBeRepaidAndWithdrawn() public {
        vm.prank(guardian);
        policy.disableToken(Currency.wrap(RobinhoodChain.NATIVE));

        _repayInFull();

        vm.startPrank(borrower);
        market.withdrawCollateral(tokenId, borrower);
        nft.approve(address(market), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, Currency.wrap(RobinhoodChain.NATIVE))
        );
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    function test_aLoanOnADisabledTokenCanBeLiquidated() public {
        _ageUntilUnderWater();
        vm.prank(guardian);
        policy.disableToken(Currency.wrap(RobinhoodChain.NATIVE));

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "a position on a disabled token must still be liquidatable");
    }

    /* ------------------------------- revokeHook ------------------------------- */

    /// @notice A position behind a hook the guardian revoked: no new one enters the pool, and
    ///         the loan that exists is repaid as before.
    function test_aLoanBehindARevokedHookCanBeRepaidAndWithdrawn() public {
        (uint256 hooked, PoolKey memory hookedKey) = _openBehindAllowlistedHook();

        vm.prank(guardian);
        policy.revokeHook(REMOVAL_HAIRCUT_HOOK);

        // Read first: a call inside the argument list would be the one `expectRevert` watches.
        ICollateralPolicy.Tier tier = market.tier();
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.HookNotPermitted.selector, REMOVAL_HAIRCUT_HOOK));
        policy.checkPool(hookedKey, tier);

        deal(address(usdg), address(this), market.debtOf(hooked));
        usdg.approve(address(market), type(uint256).max);
        market.repay(hooked, type(uint256).max);
        assertEq(market.debtOf(hooked), 0, "the debt was not repaid");

        market.withdrawCollateral(hooked, address(this));
        assertEq(nft.ownerOf(hooked), address(this), "the position did not come home");
    }

    /// @dev The oracle is moved rather than the loan aged: only the branch is asserted here,
    ///      never the payout, so the gap between oracle and pool measures nothing.
    function test_aLoanBehindARevokedHookCanBeLiquidated() public {
        (uint256 hooked,) = _openBehindAllowlistedHook();
        oracle.set(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT * 60 / 100, 18);
        assertLt(lens.healthFactor(hooked), 1e18, "the position did not go under water");

        vm.prank(guardian);
        policy.revokeHook(REMOVAL_HAIRCUT_HOOK);

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(hooked, type(uint256).max, 0, 0, liquidator);
        assertGt(repaid, 0, "a position behind a revoked hook must still be liquidatable");
    }

    /* ---------------------------------- pause --------------------------------- */

    /// @notice The guardian's pause is the owner's pause: it stops borrowing, and leaves the way
    ///         out open. A borrower repays and withdraws while the market is paused.
    function test_aGuardianPauseLeavesRepayAndWithdrawOpen() public {
        vm.prank(guardian);
        market.pause();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        market.borrow(tokenId, 1e6, borrower);

        _repayInFull();
        vm.prank(borrower);
        market.withdrawCollateral(tokenId, borrower);
        assertEq(nft.ownerOf(tokenId), borrower, "a guardian's pause trapped the position");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev Lists the fixture's pool, takes the position in, funds the vault and borrows to the
    ///      limit, as `MarketLiquidateForkTest._open` does.
    function _open() private {
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

        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);

        deal(address(usdg), liquidator, 2000e6);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    /// @dev A second position, minted behind a hook that needs the allowlist, with a loan on it.
    ///      This test contract is its borrower.
    function _openBehindAllowlistedHook() private returns (uint256 hooked, PoolKey memory hookedKey) {
        hooked = _mintRemovalHaircutPosition(0, 1e14);
        hookedKey = _keyOf(hooked);
        _listPool(hookedKey, 50e18, 0);

        IERC721(RobinhoodChain.POSITION_MANAGER).approve(address(market), hooked);
        market.depositCollateral(hooked);
        uint256 amount = lens.maxBorrow(hooked);
        // The first loan took what the vault held; this one needs cash of its own.
        deal(address(usdg), lender, amount);
        vm.prank(lender);
        market.deposit(amount, lender);
        market.borrow(hooked, amount, address(this));
    }

    function _repayInFull() private {
        uint256 debt = market.debtOf(tokenId);
        deal(address(usdg), borrower, debt);
        vm.startPrank(borrower);
        usdg.approve(address(market), type(uint256).max);
        market.repay(tokenId, type(uint256).max);
        vm.stopPrank();
        assertEq(market.debtOf(tokenId), 0, "the debt was not repaid");
    }

    /// @dev Interest does it, so the oracle stays on the pool's own price.
    function _ageUntilUnderWater() private {
        for (uint256 i = 0; i < 4000; ++i) {
            if (lens.healthFactor(tokenId) < 1e18) return;
            vm.warp(block.timestamp + 1 days);
            market.accrue();
        }
        revert("the health factor never fell far enough");
    }
}
