// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {MarketLens} from "../../src/MarketLens.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {DebtMath} from "../../src/libraries/DebtMath.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";
import {MarketLiquidation} from "../../src/libraries/MarketLiquidation.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {RedeemingLiquidator} from "../mocks/RedeemingLiquidator.sol";

/// @notice §8 against a real position: both seizure branches, the fee credit, the protocol
///         fee, the haircut, and §9's bad debt.
/// @dev Two ways of making the fixture liquidatable, and which one a test uses matters.
///
///      `_ageUntilHealthFactorBelow` lets interest do it, leaving the oracle exactly on the
///      pool's own price. Every test that measures what the liquidator *received* uses that
///      one, because the seizure is sized at oracle prices while the tokens come out at pool
///      prices: an LP bundle is worth least, valued externally, precisely when the pool agrees
///      with the oracle, so any gap pays the liquidator more than `repay × (1 + bonus)`. That
///      is inherent to §5.1's oracle-priced valuation, not a defect here — but it means a
///      payout assertion under a moved oracle would be measuring the gap, not the code.
///
///      `_dropEthPrice` moves the oracle instead, which is the only way to reach a shortfall
///      large enough for the full-seizure branch. Tests using it assert *which* branch ran and
///      what happened to the debt, never the exact payout.
contract MarketLiquidateForkTest is MarketForkTest {
    uint16 internal constant REMOVAL_HAIRCUT_BPS = 1000;
    uint256 internal constant PAYOUT_TOLERANCE_USD = 1e16;

    address internal lender = address(0x1E4DE2);
    address internal liquidator = address(0x11D);

    uint256 internal tokenId;
    address internal borrower;

    /// @dev Held rather than read through `market.asset()` at the call site: that is an
    ///      external call, and one inside a pranked statement spends the prank before the
    ///      statement it was meant for.
    IERC20 internal usdg;

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        borrower = IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);
        usdg = IERC20(market.asset());
    }

    /* --------------------------------- the gate ------------------------------- */

    function test_aHealthyPositionCannotBeLiquidated() public {
        _open(0);
        _fundLiquidator(1000e6);

        assertGt(lens.healthFactor(tokenId), 1e18, "the fixture should start healthy");
        vm.prank(liquidator);
        vm.expectPartialRevert(MarketLiquidation.PositionIsHealthy.selector);
        market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
    }

    /// @dev A position nobody deposited has no terms, no owner and no debt. It must be refused
    ///      by name rather than by whatever the policy happens to say about its pool.
    function test_aPositionTheMarketDoesNotHoldCannotBeLiquidated() public {
        _open(0);
        _fundLiquidator(1000e6);

        vm.prank(liquidator);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketLiquidation.PositionNotCollateral.selector, Fixtures.POS_WETH_USDG_WIDE_IN_RANGE
            )
        );
        market.liquidate(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE, 1e6, 0, 0, liquidator);
    }

    /// @notice A partial seizure that repays nothing is refused: it would still realise the
    ///         borrower's whole fee balance, for the price of gas.
    function test_aRepayOfNothingIsRefused() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.NothingToRepay.selector, tokenId));
        market.liquidate(tokenId, 0, 0, 0, liquidator);
    }

    /// @notice The seized tokens have to go somewhere real: not nowhere, and not back into the
    ///         market, where they would sit as a balance nobody owns.
    function test_theSeizureNeedsARealRecipient() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.InvalidRecipient.selector, address(0)));
        market.liquidate(tokenId, type(uint256).max, 0, 0, address(0));

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.InvalidRecipient.selector, address(market)));
        market.liquidate(tokenId, type(uint256).max, 0, 0, address(market));
    }

    /// @notice §4.1 v0.43 on the partial branch, which pays by plain transfer: `address(1)` and
    ///         `address(2)` would burn the seizure at a precompile, and PositionManager would hold
    ///         the ERC-20 leg for anyone to `SWEEP`.
    function test_thePartialSeizureRefusesWhatPositionManagerReadsAsSomeoneElse() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        _assertTheRecipientIsRefused(address(1));
        _assertTheRecipientIsRefused(address(2));
        _assertTheRecipientIsRefused(address(positionManager));

        vm.prank(liquidator);
        (,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
        assertEq(badDebt, 0, "this test needs the partial branch");
    }

    /// @notice §4.1 v0.43 on the full branch, where `TAKE_PAIR` is handed `to` as it came:
    ///         `address(1)` is the market, so the seizure would sit there with its ETH open to
    ///         `rescueUnaccountedEth` and its USDG to nobody; `address(2)` and PositionManager are
    ///         PositionManager's own balance, which anyone empties with `SWEEP`.
    function test_theFullSeizureRefusesWhatPositionManagerReadsAsSomeoneElse() public {
        _open(0);
        _fundLiquidator(2000e6);
        _dropEthPrice(1200e18);

        _assertTheRecipientIsRefused(address(1));
        _assertTheRecipientIsRefused(address(2));
        _assertTheRecipientIsRefused(address(positionManager));

        vm.prank(liquidator);
        (,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
        assertGt(badDebt, 0, "this test needs the full-seizure branch");
    }

    /// @dev The refusal, and that it left nothing behind: no ETH or USDG in the market or in
    ///      PositionManager, the liquidator's USDG unspent, and the debt where it was.
    function _assertTheRecipientIsRefused(
        address to
    ) private {
        address pm = address(positionManager);
        uint256 marketEth = address(market).balance;
        uint256 marketUsdg = usdg.balanceOf(address(market));
        uint256 pmEth = pm.balance;
        uint256 pmUsdg = usdg.balanceOf(pm);
        uint256 liquidatorUsdg = usdg.balanceOf(liquidator);
        uint256 debt = market.debtOf(tokenId);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.InvalidRecipient.selector, to));
        market.liquidate(tokenId, type(uint256).max, 0, 0, to);

        assertEq(address(market).balance, marketEth, "no ETH stops at the market");
        assertEq(usdg.balanceOf(address(market)), marketUsdg, "and no USDG");
        assertEq(pm.balance, pmEth, "no ETH is left in PositionManager for a SWEEP");
        assertEq(usdg.balanceOf(pm), pmUsdg, "and no USDG");
        assertEq(usdg.balanceOf(liquidator), liquidatorUsdg, "the liquidator paid nothing");
        assertEq(market.debtOf(tokenId), debt, "and the debt is where it was");
    }

    /// @dev §4.1 puts `liquidate` in the paused set: it reads oracle prices, and a pause is
    ///      the admission that those cannot be trusted right now.
    function test_pausingStopsLiquidation() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        vm.prank(owner);
        market.pause();

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
    }

    /// @notice §6.5: freezing a pool stops new collateral and new borrowing, and nothing else.
    /// @dev Liquidation in particular must stay open. A freeze that switched it off would
    ///      manufacture the bad debt the freeze was called to contain.
    function test_freezingThePoolDoesNotStopLiquidation() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        PoolId poolId = _keyOf(tokenId).toId();
        vm.prank(owner);
        policy.setFrozen(poolId, true);

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
        assertGt(repaid, 0, "a frozen pool must still be liquidatable");
    }

    /* ------------------------------- close factor ----------------------------- */

    /// @notice §6.2: while the shortfall is small, one liquidation may take half the debt and
    ///         no more — the ticket's case exactly, a liquidator offering the whole debt.
    function test_blueChipClosesHalfWhileTheShortfallIsSmall() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);
        assertGt(lens.healthFactor(tokenId), 0.9e18, "this test needs the partial close factor");

        // Read before the prank, and passed as a local: see the note on `usdg` above.
        uint256 debt = market.debtOf(tokenId);
        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, debt, 0, 0, liquidator);

        assertEq(repaid, debt / 2, "half the debt, though the whole debt was offered");
        assertApproxEqAbs(market.debtOf(tokenId), debt - repaid, 1, "the rest stays owed");
        assertEq(market.loanOf(tokenId).owner, borrower, "a partial seizure leaves the position with its owner");
        assertEq(IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId), address(market), "the NFT stays in custody");
    }

    /// @notice §6.2: under a health factor of 0,9 the whole debt may go at once.
    function test_blueChipClosesInFullOnceWellUnderWater() public {
        _open(0);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(0.9e18);

        uint256 debt = market.debtOf(tokenId);
        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(repaid, debt, "the close factor no longer holds anything back");
        assertEq(market.debtOf(tokenId), 0, "the debt is gone");
        assertEq(market.loanOf(tokenId).debtShares, 0, "and so are its shares");
    }

    /* ----------------------------- what it costs ------------------------------ */

    /// @notice §6.2 v0.8: the liquidator pays `repay × 1,005` on a 5% bonus pool, and the
    ///         half-percent is reserve the moment it lands.
    function test_theProtocolFeeIsPaidByTheLiquidatorIntoReserves() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        // Settle interest first, so the reserve movement this measures is the fee alone.
        market.accrue();
        uint256 reservesBefore = market.reserves();
        uint256 walletBefore = usdg.balanceOf(liquidator);

        vm.prank(liquidator);
        (uint256 repaid,, uint256 out1,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        // The seized USDG lands in the same wallet the repayment left, so it has to be netted
        // back out before the balance says what the liquidation cost.
        uint256 spent = walletBefore + out1 - usdg.balanceOf(liquidator);
        assertEq(spent, repaid + repaid * 50 / 10_000, "the liquidator pays repay x 1,005");
        assertEq(market.reserves() - reservesBefore, repaid * 50 / 10_000, "reserves grow by exactly the fee");
    }

    /// @notice The seized tokens reach the liquidator, native ETH included (§8).
    function test_ethAndUsdgBothReachTheLiquidator() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        uint256 ethBefore = liquidator.balance;
        uint256 usdgBefore = usdg.balanceOf(liquidator);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out0, uint256 out1,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(out0, 0, "the ETH leg must actually be seized");
        assertEq(liquidator.balance - ethBefore, out0, "native ETH reaches the liquidator");
        assertEq(
            usdg.balanceOf(liquidator),
            usdgBefore - repaid - repaid * 50 / 10_000 + out1,
            "the USDG leg nets off against what was paid in"
        );
    }

    /// @notice A permitted delta hook can really keep the listed haircut, while the real
    ///         PositionManager and Market still leave the liquidator below its bonus ceiling.
    /// @dev The hook code is installed at 0x101 only because v4 reads hook permissions from the
    ///      address. The pool, position, oracle and liquidation are otherwise the pinned fork's.
    function test_aDeltaHookHaircutKeepsLiquidatorAtBonusCeiling() public {
        _openRemovalHaircutPosition(REMOVAL_HAIRCUT_BPS);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        uint256 hookWethBefore = IERC20(RobinhoodChain.WETH).balanceOf(REMOVAL_HAIRCUT_HOOK);
        uint256 hookUsdgBefore = usdg.balanceOf(REMOVAL_HAIRCUT_HOOK);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out0, uint256 out1,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "the hook pool must liquidate");
        assertGt(
            IERC20(RobinhoodChain.WETH).balanceOf(REMOVAL_HAIRCUT_HOOK) - hookWethBefore
                + usdg.balanceOf(REMOVAL_HAIRCUT_HOOK) - hookUsdgBefore,
            0,
            "the delta hook must keep its configured haircut"
        );
        uint256 payoutUsd = _wethUsdgValue(out0, out1);
        uint256 bonusPayoutUsd = repaid * 1e12 * 10_500 / 10_000;
        assertGe(
            payoutUsd + PAYOUT_TOLERANCE_USD,
            bonusPayoutUsd,
            "the hook haircut must not leave the liquidator below the bonus payout"
        );
        assertLe(
            payoutUsd,
            bonusPayoutUsd + PAYOUT_TOLERANCE_USD,
            "the independently valued payout exceeded repay x (1 + bonus)"
        );
    }

    /// @notice The removal haircut also decides the liquidation gate, not only the payout.
    function test_theLiquidationGateCountsTheRemovalHaircut() public {
        _openRemovalHaircutPosition(REMOVAL_HAIRCUT_BPS);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(1e18);

        uint256 health = lens.healthFactor(tokenId);
        assertGe(health * 10_000 / (10_000 - REMOVAL_HAIRCUT_BPS), 1e18, "without the haircut the loan is healthy");
        uint256 debt = market.debtOf(tokenId);

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "the haircut-only liquidation must proceed");
        assertLt(market.debtOf(tokenId), debt, "the liquidation must reduce debt");
    }

    /// @notice Even at the accepted 2,000 bps ceiling, liquidation cannot seize for zero repay.
    function test_theHaircutCeilingCannotEnableAZeroRepaySeizure() public {
        _openRemovalHaircutPosition(2000);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(1e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 out0, uint256 out1,) = market.liquidate(tokenId, 1, 0, 0, liquidator);

        assertGt(repaid, 0, "a ceiling haircut must still require repayment");
        assertGt(out0 + out1, 0, "the liquidator must receive the seized position output");
    }

    /// @notice A partial seizure pays out what it charged for: the slice of liquidity plus the fee
    ///         credit, worth at least `repay × (1 + bonus)`, and the position shrinks by exactly
    ///         the liquidity that slice needs.
    /// @dev The floor to the fuzz's ceiling. On the natural fixture the seizure outruns the fees,
    ///      so real liquidity has to come out; a slice that pulled none would still hand over the
    ///      fees and leave every other assertion green (review of PR #16, mutation M1). The payout
    ///      is valued at oracle prices, which on this fixture sit on the pool's own price.
    function test_aPartialSeizurePaysTheSliceItChargedFor() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);
        assertGt(lens.healthFactor(tokenId), 0.9e18, "this test needs the partial close factor");

        uint256 repay = market.debtOf(tokenId) / 2;
        uint256 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        uint256 slice = _expectedSlice(repay);
        assertGt(slice, 0, "the seizure must outrun the fees and pull liquidity");

        vm.prank(liquidator);
        (uint256 repaid, uint256 out0, uint256 out1,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(repaid, repay, "with no fees left over, only the close factor is repaid");
        assertEq(
            liquidityBefore - positionManager.getPositionLiquidity(tokenId), slice, "the position shrank by the slice"
        );
        assertGe(
            _usdValue(out0, out1),
            repay * 1e12 * 10_500 / 10_000 * 9990 / 10_000,
            "the liquidator received the seizure it paid for, within 0,1% of rounding"
        );
    }

    /// @notice The minimums are measured on what the liquidator receives (§8 step 5), not on
    ///         what reached the market.
    function test_slippageIsCheckedOnWhatTheLiquidatorReceives() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        (uint256 expected0, uint256 expected1) = _previewSeizure(type(uint256).max);

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketLiquidation.SeizureBelowMinimum.selector);
        market.liquidate(tokenId, type(uint256).max, uint128(expected0 * 2), 0, liquidator);

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketLiquidation.SeizureBelowMinimum.selector);
        market.liquidate(tokenId, type(uint256).max, 0, uint128(expected1 * 2), liquidator);

        vm.prank(liquidator);
        market.liquidate(tokenId, type(uint256).max, uint128(expected0), uint128(expected1), liquidator);
    }

    /// @notice §8 step 5 v0.26: the minimums cover everything the liquidator receives, the bought
    ///         fee leg included, and nothing that goes back to the borrower.
    /// @dev Run where the fees outrun the whole debt, so the market takes delivery of more ETH
    ///      than the liquidator gets: part of it is bought, the rest returns to the borrower. A
    ///      check against what arrived would accept a minimum the liquidator never receives
    ///      (review of PR #16, mutation M2).
    function test_theMinimumsCoverTheBoughtLegButNotTheBorrowersShare() public {
        _openWithDonatedFees(_ethWorth(2000e18), 0);
        uint256 borrowerEth = borrower.balance;
        (uint256 expected0, uint256 expected1) = _previewSeizure(type(uint256).max);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.SeizureBelowMinimum.selector, expected0, expected1));
        market.liquidate(tokenId, type(uint256).max, uint128(expected0 + 1), 0, liquidator);

        vm.prank(liquidator);
        (, uint256 out0,,) =
            market.liquidate(tokenId, type(uint256).max, uint128(expected0), uint128(expected1), liquidator);
        assertEq(out0, expected0, "the minimum is exactly what the liquidator received");
        assertGt(borrower.balance, borrowerEth, "while the ETH beyond it went to the borrower");
    }

    /* ------------------------------- the v0.2 gap ----------------------------- */

    /// @notice The regression that gave §8 step 5 its shape, in its v0.26 form: a tiny repay
    ///         against a position with fees cannot collect them, and cannot hand them back to
    ///         a borrower still in debt either.
    /// @dev A decrease realises every fee in the position however little liquidity it pulls.
    ///      v0.2 paid all of it to the liquidator. Until v0.26 the part beyond the seizure went
    ///      back to the borrower, which a 1-wei repay could trigger at will to move collateral out
    ///      and push the health factor down (review of PR #16). Now the ETH part must be bought,
    ///      and a `repayAmount` that leaves nothing to buy it with is refused.
    function test_aTinyRepayCannotDrainTheFeeBalance() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);
        assertGt(valuer.valueForLiquidation(tokenId).fees0, 0, "the fixture must carry an ETH fee leg");

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketLiquidation.FeePurchaseUnderfunded.selector);
        market.liquidate(tokenId, 1, 0, 0, liquidator);

        vm.prank(liquidator);
        vm.expectPartialRevert(MarketLiquidation.FeePurchaseUnderfunded.selector);
        market.liquidate(tokenId, 1e6, 0, 0, liquidator);
    }

    /// @notice §8 step 5 v0.26: the fees the seizure was not entitled to repay the debt — the
    ///         USDG leg directly, the ETH leg by being bought — and none of it reaches a borrower
    ///         still in debt.
    function test_theFeesLeftOverAreBoughtAndRepayTheDebt() public {
        _openWithDonatedFees(_ethWorth(250e18), 0);
        assertGt(lens.healthFactor(tokenId), 0.9e18, "this test needs the partial close factor");

        // Kept to few locals on purpose: CI's `lite` profile compiles without the optimizer,
        // where a test this size runs out of stack slots.
        uint256 debtBefore = market.debtOf(tokenId);
        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        (uint256 appliedUsdg, uint256 cost, uint256 keptEth) = _expectedLeftover(v, debtBefore / 2, debtBefore);
        assertGt(keptEth, 0, "the fees must outrun the seizure and leave an ETH leg behind");
        assertLt(appliedUsdg + cost, debtBefore - debtBefore / 2, "and still fit under the remaining debt");

        // [borrower ETH, borrower USDG, liquidator USDG]
        uint256[3] memory before = [borrower.balance, usdg.balanceOf(borrower), usdg.balanceOf(liquidator)];

        vm.prank(liquidator);
        (uint256 repaid, uint256 out0, uint256 out1,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(borrower.balance, before[0], "no ETH reaches a borrower still in debt");
        assertEq(usdg.balanceOf(borrower), before[1], "and no USDG either");
        assertEq(repaid, debtBefore / 2 + appliedUsdg + cost, "the debt fell by repay, the USDG fees, and the purchase");
        // Within a unit: shares are retired rounded down, the same rule `repay` follows.
        assertApproxEqAbs(market.debtOf(tokenId), debtBefore - repaid, 1, "the ledger records what was repaid");

        assertEq(
            before[2] + out1 - usdg.balanceOf(liquidator),
            debtBefore / 2 + (debtBefore / 2) * 50 / 10_000 + cost,
            "the liquidator paid repay, its fee, and the leg's value"
        );
        assertEq(out0, v.fees0, "and took the whole ETH fee leg: the seizure's share plus what it bought");
        assertEq(out1, v.fees1 - appliedUsdg, "while the USDG beyond its share stayed to repay the debt");
    }

    /// @notice The edge of `FeePurchaseUnderfunded`, from both sides: a `repayAmount` covering
    ///         the close factor and the purchase exactly goes through, and one unit less is refused
    ///         with precisely what was required and what was there.
    function test_theFeePurchaseMustBeFundedToTheUnit() public {
        _openWithDonatedFees(_ethWorth(250e18), 0);
        uint256 debt = market.debtOf(tokenId);
        uint256 repay = debt / 2;
        (uint256 appliedUsdg, uint256 cost,) = _expectedLeftover(valuer.valueForLiquidation(tokenId), repay, debt);
        assertGt(cost, 0, "this test needs a purchase");

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(MarketLiquidation.FeePurchaseUnderfunded.selector, cost, cost - 1));
        market.liquidate(tokenId, repay + cost - 1, 0, 0, liquidator);

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, repay + cost, 0, 0, liquidator);
        assertEq(repaid, repay + appliedUsdg + cost, "the exact budget buys the whole leg, to the unit");
    }

    /// @notice While debt remains, every dollar of fees that leaves the position takes a dollar of
    ///         debt with it. Only the bonus on the seizure itself is not matched.
    /// @dev Before v0.26 the ETH leg left for the borrower's wallet while the debt stayed, and the
    ///      health factor paid for it: review of PR #16 measured 0,99990 → 0,98961 on this
    ///      fixture with a 1-wei repay, and 0,97 → 0,88 on a fee-heavy position.
    function test_feesLeavingThePositionTakeTheirDebtWithThem() public {
        _openWithDonatedFees(_ethWorth(250e18), 0);
        uint256 debtBefore = market.debtOf(tokenId);
        uint256 valueBefore = _realizableUsd();

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        uint256 valueLost = valueBefore - _realizableUsd();
        uint256 bonusUsd = (debtBefore / 2) * 1e12 * 500 / 10_000;
        // Within a few millionths of a dollar: each leg is priced and rounded on its own, the
        // purchase price up and the fee split up, one USDG unit (1e12) apiece at most.
        assertApproxEqAbs(
            repaid * 1e12 + bonusUsd, valueLost, 5e12, "the debt fell by all the position lost, bar the bonus"
        );
        assertApproxEqAbs(market.debtOf(tokenId), debtBefore - repaid, 1, "and the ledger agrees, within a unit");
    }

    /// @notice §8 step 5 v0.26: once the leftover fees cover the whole remaining debt, the debt is
    ///         repaid in full and only what lies beyond it goes back to the borrower.
    function test_feesBeyondTheDebtRepayItAndOnlyTheRestGoesBack() public {
        _openWithDonatedFees(_ethWorth(2000e18), 0);
        uint256 debtBefore = market.debtOf(tokenId);
        uint256 borrowerEth = borrower.balance;
        uint256 walletBefore = usdg.balanceOf(liquidator);

        vm.prank(liquidator);
        (uint256 repaid,, uint256 out1,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(repaid, debtBefore, "the fees paid off the whole debt");
        assertEq(market.debtOf(tokenId), 0, "and the ledger says so");
        assertEq(market.loanOf(tokenId).owner, borrower, "the position is still the borrower's");
        assertGt(borrower.balance, borrowerEth, "what the debt could not absorb came back to them");

        uint256 spent = walletBefore + out1 - usdg.balanceOf(liquidator);
        assertLe(spent, debtBefore + (debtBefore / 2) * 50 / 10_000, "the liquidator paid no more than debt and fee");
    }

    /* ------------------------- a borrower that refuses ETH -------------------- */

    /// @notice A contract borrower that reverts on ETH cannot block its own liquidation. Its
    ///         share of the fees reaches it as WETH instead.
    /// @dev Since v0.26 anything goes back to the borrower only once its leftover fees outrun both
    ///      the seizure and the whole remaining debt, and no `repayAmount` avoids that. So the
    ///      block has to be impossible, not just avoidable.
    function test_aBorrowerThatRejectsEthIsPaidInWethAndStillLiquidated() public {
        _assertTheBorrowersEthFallsBackToWeth(hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT
    }

    /// @notice The same for a borrower that burns every unit of gas it is handed, which would
    ///         otherwise take the liquidation down with it.
    function test_aBorrowerThatBurnsTheGasIsPaidInWethAndStillLiquidated() public {
        _assertTheBorrowersEthFallsBackToWeth(hex"5b600056"); // JUMPDEST PUSH1 0 JUMP
    }

    function _assertTheBorrowersEthFallsBackToWeth(
        bytes memory borrowerCode
    ) private {
        _openWithDonatedFees(_ethWorth(2000e18), 0);
        vm.etch(borrower, borrowerCode);

        IERC20 weth = IERC20(RobinhoodChain.WETH);
        uint256 ethBefore = borrower.balance;
        uint256 wethBefore = weth.balanceOf(borrower);
        uint256 marketEthBefore = address(market).balance;

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "the liquidation must go through");
        assertEq(borrower.balance, ethBefore, "the borrower took no ETH");
        assertGt(weth.balanceOf(borrower), wethBefore, "its share arrived as WETH");
        assertEq(address(market).balance, marketEthBefore, "and none of it stayed in the market");
    }

    /// @notice §8 step 5: USDG fees beyond the whole debt go back to the borrower, to the unit.
    /// @dev Review of PR #16, mutation M3: without the refund the excess quietly becomes
    ///      depositors' cash, and no test noticed.
    function test_usdgFeesBeyondTheDebtAreRefundedToTheBorrower() public {
        _openWithDonatedFees(0, 2000e6);
        assertGt(lens.healthFactor(tokenId), 0.9e18, "this test needs the partial close factor");
        uint256 refund = _expectedUsdgRefund();
        assertGt(refund, 0, "the USDG fees must outrun the whole debt");
        uint256 borrowerUsdg = usdg.balanceOf(borrower);

        vm.prank(liquidator);
        market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(market.debtOf(tokenId), 0, "the fees paid off the debt");
        assertEq(usdg.balanceOf(borrower) - borrowerUsdg, refund, "and the rest came back, to the unit");
    }

    /// @notice A borrower that cannot receive a token — USDG's issuer can freeze an address —
    ///         cannot block its own liquidation when the fees beyond its debt come back to it.
    /// @dev Review of PR #16, point 2.3. The ETH leg already fell back to WETH, but the ERC-20 leg
    ///      was a plain transfer, so a frozen borrower made the whole liquidation revert.
    function test_aBorrowerThatCannotReceiveUsdgCannotBlockItsLiquidation() public {
        _openWithDonatedFees(0, 2000e6);
        assertGt(_expectedUsdgRefund(), 0, "there must be USDG to refund, or the freeze is never exercised");
        uint256 borrowerUsdg = usdg.balanceOf(borrower);
        vm.mockCallRevert(address(usdg), abi.encodeWithSelector(IERC20.transfer.selector, borrower), "frozen");

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(repaid, 0, "the liquidation must go through");
        assertEq(market.debtOf(tokenId), 0, "the USDG fees paid off the debt");
        assertEq(usdg.balanceOf(borrower), borrowerUsdg, "the borrower got nothing it could not take");
    }

    /* ------------------------------- full seizure ----------------------------- */

    /// @notice §8 step 4 and §9: when the position cannot cover the debt, it is taken whole,
    ///         burned, and what is left over becomes bad debt.
    function test_aPositionThatCannotCoverItsDebtIsBurnedAndTheRestSocialized() public {
        _open(0);
        _fundLiquidator(2000e6);
        _dropEthPrice(1200e18);

        uint256 debt = market.debtOf(tokenId);
        uint256 sharePriceBefore = market.convertToAssets(1e9);

        vm.prank(liquidator);
        (uint256 repaid,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(badDebt, 0, "a position worth less than its debt leaves a shortfall");
        assertEq(badDebt, debt - repaid, "and the shortfall is what the repayment did not cover");
        assertEq(market.loanOf(tokenId).owner, address(0), "the loan record is gone");
        assertEq(market.totalBorrows(), 0, "the debt left the book with the position");

        vm.expectRevert();
        IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);

        assertLt(market.convertToAssets(1e9), sharePriceBefore, "bad debt beyond the reserve reaches depositors");
    }

    /// @notice §8: native ETH reaches the liquidator on the full branch too, and it goes there
    ///         directly — `TAKE_PAIR` addresses `to`, so none of it passes through the market.
    /// @dev The partial branch has its own test above; this one exists because the two routes
    ///      share nothing below `execute`, and only the full one relies on PositionManager
    ///      paying ETH out to an address the market does not control.
    function test_theFullSeizurePaysNativeEthStraightToTheLiquidator() public {
        _open(0);
        _fundLiquidator(2000e6);
        _dropEthPrice(1200e18);

        uint256 liquidatorEthBefore = liquidator.balance;
        uint256 marketEthBefore = address(market).balance;

        vm.prank(liquidator);
        (, uint256 out0,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(badDebt, 0, "this test needs the full-seizure branch");
        assertGt(out0, 0, "the ETH leg must actually be seized");
        assertEq(liquidator.balance - liquidatorEthBefore, out0, "native ETH reaches the liquidator");
        assertEq(address(market).balance, marketEthBefore, "and none of it stops at the market");
    }

    /// @notice §9: bad debt takes the whole reserve first, including the part §7 keeps the
    ///         owner away from, and only the remainder touches depositors.
    function test_badDebtEmptiesTheReserveBeforeItReachesDepositors() public {
        _open(0);
        _fundLiquidator(2000e6);
        // Let interest build a reserve worth watching, then break the position.
        _ageUntilHealthFactorBelow(0.95e18);
        _dropEthPrice(1200e18);

        uint256 reservesBefore = market.reserves();
        assertGt(reservesBefore, 0, "this test needs a reserve to spend");
        assertGt(reservesBefore, lens.reserveFloor(), "and part of it below the withdrawal floor");
        uint256 totalAssetsBefore = market.totalAssets();

        vm.recordLogs();
        vm.prank(liquidator);
        (uint256 repaid,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        // The reserve the shortfall meets is what was there plus the fee this call just paid in.
        uint256 available = reservesBefore + repaid * 50 / 10_000;
        assertGt(badDebt, available, "the shortfall must outgrow the reserve here");
        assertEq(market.reserves(), 0, "the reserve is spent to the last unit, floor included");
        assertEq(_socializedAmount(), badDebt - available, "only the uncovered part reaches depositors");

        // §9 layer 3, measured where depositors feel it. Cash gains repay + fee, `totalBorrows`
        // loses the whole debt, `reserves` loses everything it held: the covered part cancels
        // out, and what `totalAssets` loses is the socialized part to the unit.
        assertEq(
            totalAssetsBefore - market.totalAssets(), badDebt - available, "depositors lose the uncovered part, no more"
        );
    }

    /// @notice §9 layer 2: a bad debt the reserve can cover is paid from the reserve alone.
    ///         Depositors lose nothing, and nothing is socialized.
    /// @dev The position is priced just under what the full seizure needs, so the branch is the
    ///      full one but the shortfall is small. The other bad-debt tests only ever had more bad
    ///      debt than reserve, so a reserve emptied on every bad debt passed them (review of PR
    ///      #16, mutation M4).
    function test_badDebtTheReserveCanCoverNeverReachesDepositors() public {
        _open(0);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(0.95e18);
        _priceRealizableValueAt(market.debtOf(tokenId) * 1e12 * 1048 / 1000);

        uint256 reservesBefore = market.reserves();
        uint256 totalAssetsBefore = market.totalAssets();

        vm.recordLogs();
        vm.prank(liquidator);
        (uint256 repaid,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        uint256 fee = repaid * 50 / 10_000;
        assertGt(badDebt, 0, "this test needs the full branch to leave a shortfall");
        assertGt(reservesBefore + fee, badDebt, "and the reserve must be able to cover all of it");
        assertEq(market.reserves(), reservesBefore + fee - badDebt, "the reserve pays the shortfall, and only that");
        assertEq(market.totalAssets(), totalAssetsBefore, "depositors lose nothing");
        assertFalse(_emitted(keccak256("BadDebtSocialized(uint256)")), "and nothing is socialized");
    }

    /* -------------------------------- reentrancy ------------------------------ */

    /// @notice A lender that liquidates into its own address and redeems from inside the ETH
    ///         payout gets what its shares are worth after the liquidation, not before it.
    /// @dev The full branch is where this matters most. Until the ledger is written, the debt
    ///      about to be socialized still counts toward `totalAssets`, so a redeem read at that
    ///      moment walks away from the loss and leaves all of it to the other depositors.
    function test_aRedeemFromInsideTheFullSeizurePayoutStillBearsTheBadDebt() public {
        RedeemingLiquidator attacker = _openWithRedeemingLiquidator();
        _dropEthPrice(1200e18);

        uint256 badDebt = _assertRedeemIsPricedAfterTheLiquidation(attacker);
        assertGt(badDebt, 0, "this test needs the full-seizure branch");
    }

    /// @notice The same on the partial branch, where the USDG the liquidation brought in would
    ///         otherwise still be counted in `totalAssets` while the ETH goes out.
    function test_aRedeemFromInsideThePartialSeizurePayoutGainsNothing() public {
        RedeemingLiquidator attacker = _openWithRedeemingLiquidator();
        _ageUntilHealthFactorBelow(1e18);

        uint256 badDebt = _assertRedeemIsPricedAfterTheLiquidation(attacker);
        assertEq(badDebt, 0, "this test needs the partial branch");
    }

    function _openWithRedeemingLiquidator() private returns (RedeemingLiquidator attacker) {
        _open(0);
        _fundLiquidator(2000e6);
        attacker = new RedeemingLiquidator(market);
        deal(address(usdg), address(attacker), 2300e6);
        attacker.deposit(300e6);
    }

    /// @dev Runs the same liquidation twice from the same state: once by an ordinary
    ///      liquidator, to read what the attacker's shares are worth afterwards, and once by the
    ///      attacker, redeeming from inside its own payout.
    function _assertRedeemIsPricedAfterTheLiquidation(
        RedeemingLiquidator attacker
    ) private returns (uint256 badDebt) {
        uint256 shares = market.balanceOf(address(attacker));
        uint256 snapshot = vm.snapshotState();
        vm.prank(liquidator);
        market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
        uint256 fair = market.previewRedeem(shares);
        vm.revertToState(snapshot);

        badDebt = attacker.liquidate(tokenId, type(uint256).max);

        assertGt(attacker.redeemed(), 0, "the redeem must actually run inside the payout");
        assertLe(attacker.redeemed(), fair, "a share redeemed mid-liquidation is worth no more than after it");
    }

    /* ------------------------------ the price gates --------------------------- */

    /// @notice §5.2: every condition that blocks a borrow leaves liquidation running. The AC
    ///         FAR-20 could not test, since `liquidate` did not exist yet (moved here by the
    ///         review of PR #14).
    /// @dev The gates go on one at a time and neither comes off: spot first, then USDG outside
    ///      [0,97; 1,03]. `borrow` checks them in the reverse order (USDG, spot), so the second
    ///      gate becomes the one a borrow hits, which proves it is live on top of the one already
    ///      set. A test that only moved prices would pass whether the gates worked or not (review
    ///      of PR #16, 2.2). With both shut in the same state, the liquidation still goes through.
    function test_liquidationOutlivesEveryBorrowPriceGate() public {
        _open(0);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(1e18);

        // Spot: the pool stays put while the oracle moves 20% away from it.
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 80 / 100, 18);
        assertGt(valuer.value(tokenId).spotDeviationBps, 200, "the pool must be outside the 2% borrow gate");
        _assertBorrowRefusedBy(FarmentaMarket.SpotPriceDeviation.selector);

        // USDG: off its band.
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.9e18, RobinhoodChain.USDG_DECIMALS);
        _assertBorrowRefusedBy(FarmentaMarket.UsdgPriceOutOfBounds.selector);

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
        assertGt(repaid, 0, "a liquidation must be possible when every borrow gate is shut");
    }

    function _assertBorrowRefusedBy(
        bytes4 gate
    ) private {
        vm.prank(borrower);
        vm.expectPartialRevert(gate);
        market.borrow(tokenId, 10e6, borrower);
    }

    /// @notice The liquidation price surface is the one §8 reads, and it is not the borrow one.
    /// @dev Split the two and the position is healthy on one and underwater on the other. A
    ///      `liquidate` that read `price` would refuse this call.
    function test_liquidationReadsItsOwnPriceSurface() public {
        _open(0);
        _fundLiquidator(2000e6);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT / 2);

        assertGt(lens.healthFactor(tokenId), 1e18, "the borrow surface still calls it healthy");
        assertLt(lens.liquidationHealthFactor(tokenId), 1e18, "the lens must follow the liquidation surface");

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, 10e6, 0, 0, liquidator);
        assertEq(repaid, 10e6, "the liquidation surface is what decides");
    }

    function test_liquidationLensMatchesTheGateWithUsdPriceAndHaircut() public {
        _openRemovalHaircutPosition(500);
        _fundLiquidator(2000e6);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT * 95 / 100);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.USDG), 1.02e18);

        assertEq(lens.liquidationHealthFactor(tokenId), _healthyGateHealthFactor(), "lens must match the gate exactly");
    }

    function test_liquidationLensProjectsUnaccruedDebt() public {
        _open(0);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(1.002e18);

        vm.warp(block.timestamp + 60 days);
        assertLt(lens.liquidationHealthFactor(tokenId), 1e18, "the projected debt must make the position liquidatable");

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, 100e6, 0, 0, liquidator);
        assertGt(repaid, 0, "the gate must agree with the projected lens");
    }

    function test_liquidationCloseFactorUsesTheProjectedHealthFactor() public {
        _open(0);
        _ageUntilHealthFactorBelow(1e18);
        assertGt(lens.liquidationHealthFactor(tokenId), 0.9e18, "this needs the partial close band");
        assertEq(lens.liquidationCloseFactorBps(tokenId), 5000);
    }

    function testFuzz_liquidationLensAgreesWithTheGate(
        uint16 wethBps,
        uint16 usdgBps,
        uint40 elapsed
    ) public {
        _openRemovalHaircutPosition(500);
        _fundLiquidator(10_000e6);
        wethBps = uint16(bound(wethBps, 5000, 12_000));
        usdgBps = uint16(bound(usdgBps, 9500, 10_500));
        elapsed = uint40(bound(uint256(elapsed), 0, 365 days));
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT * wethBps / 10_000);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.USDG), ONE_USD * usdgBps / 10_000);
        vm.warp(block.timestamp + elapsed);

        uint256 healthFactor = lens.liquidationHealthFactor(tokenId);
        vm.prank(liquidator);
        (bool succeeded, bytes memory reason) =
            address(market).call(abi.encodeCall(market.liquidate, (tokenId, type(uint256).max, 0, 0, liquidator)));

        if (succeeded) {
            assertLt(healthFactor, 1e18, "a successful liquidation needs an unhealthy lens reading");
        } else {
            assertEq(bytes4(reason), MarketLiquidation.PositionIsHealthy.selector, "the only healthy-state refusal");
            assertEq(healthFactor, _healthFactorFromReason(reason), "the lens and gate health factors must agree");
        }
    }

    /* --------------------------------- meme market ---------------------------- */

    /// @notice §5.3 v0.52 (FAR-49): a meme liquidation is the one market path that records its
    ///         observation last. A count says a `record` happened, not when; what the position
    ///         held at that moment does.
    function test_aMemeLiquidationRecordsOnceTheSliceHasLeft() public {
        _openMeme();
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        PoolId poolId = _keyOf(tokenId).toId();
        uint256 records = oracle.recordCount(poolId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        oracle.watch(positionManager, tokenId);

        vm.prank(liquidator);
        market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        uint128 left = positionManager.getPositionLiquidity(tokenId);
        assertLt(left, liquidity, "the fixture should have lost a slice");
        assertEq(oracle.recordCount(poolId), records + 1, "the liquidation recorded the pool once");
        assertEq(oracle.liquidityOnLastRecord(), left, "and did so after the slice had left");
    }

    /// @notice The full branch burns the position, and with it the only way to look its pool up
    ///         by token id. The observation is still taken.
    function test_aFullMemeSeizureStillRecords() public {
        _openMeme();
        _fundLiquidator(2000e6);
        _dropEthPrice(100e18);

        PoolId poolId = _keyOf(tokenId).toId();
        uint256 records = oracle.recordCount(poolId);

        vm.prank(liquidator);
        (,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertGt(badDebt, 0, "the fixture should have gone to the full branch");
        vm.expectRevert();
        IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);
        assertEq(oracle.recordCount(poolId), records + 1, "the liquidation recorded the pool once");
    }

    /// @notice A blue-chip liquidation has no TWAP to feed, and pays nothing for one.
    function test_aBlueChipLiquidationRecordsNothing() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);

        vm.prank(liquidator);
        market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(oracle.recordCount(_keyOf(tokenId).toId()), 0, "no observation for a blue-chip pool");
    }

    /* ----------------------------------- fuzz --------------------------------- */

    /// @notice §8 step 5's invariant: whatever the liquidator asks to repay, they never walk
    ///         away with more than `repay × (1 + bonus)`.
    /// @dev The oracle sits on the pool's own price here, so the payout and the seizure are
    ///      measured in the same units — see the note on this contract.
    function testFuzz_theLiquidatorNeverReceivesMoreThanTheBonus(
        uint256 repayAmount
    ) public {
        _open(0);
        _fundLiquidator(10_000e6);
        _ageUntilHealthFactorBelow(1e18);
        market.accrue();

        repayAmount = bound(repayAmount, 1, market.debtOf(tokenId) * 2);
        uint256 reservesBefore = market.reserves();
        uint256 walletBefore = usdg.balanceOf(liquidator);

        vm.prank(liquidator);
        try market.liquidate(tokenId, repayAmount, 0, 0, liquidator) returns (
            uint256, uint256 out0, uint256 out1, uint256
        ) {
            // What the liquidator paid against the debt: everything that left their wallet, less
            // the protocol fee, which is the only other thing reserves moved by. A fee leg they
            // had to buy is in it too, paid at value, so it lifts this ceiling by as much as the
            // payout.
            uint256 spent = walletBefore + out1 - usdg.balanceOf(liquidator);
            uint256 repay = spent - (market.reserves() - reservesBefore);

            assertLe(
                _usdValue(out0, out1), repay * 1e12 * 10_500 / 10_000 + 1e12, "the payout exceeded repay x (1 + bonus)"
            );
        } catch (bytes memory reason) {
            // §8 step 5 v0.26: a request that leaves nothing to buy the fee leg with is refused.
            assertEq(
                bytes32(bytes4(reason)),
                bytes32(MarketLiquidation.FeePurchaseUnderfunded.selector),
                "the only refusal is an unfunded fee purchase"
            );
        }
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev The fixture, deposited and borrowed against up to its limit, with a lender behind
    ///      it. `haircutBps` is what the pool's listing records the hook skimming (§6.3).
    function _open(
        uint16 haircutBps
    ) private {
        _listPoolOf(tokenId, 50e18, haircutBps);
        vm.startPrank(borrower);
        IERC721(RobinhoodChain.POSITION_MANAGER).approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(usdg), lender, 300e6);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(300e6, lender);
        vm.stopPrank();

        // Read before the prank: an external call inside the argument list would spend it,
        // and the borrow would arrive from this test contract instead.
        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
    }

    /// @dev The standard fixture's hook has no removal-delta permission, so tests that model a
    ///      configured haircut must mint the same WETH/USDG shape behind the valid delta hook.
    function _openRemovalHaircutPosition(
        uint16 haircutBps
    ) private {
        tokenId = _mintRemovalHaircutPosition(haircutBps, 1e14);
        borrower = address(this);
        _open(haircutBps);
    }

    /// @dev `_open` on a meme market. Native ETH is re-tiered as meme first, which makes the pool
    ///      meme (§6.1 takes the higher tier). `market` and `lens` are repointed, so every other
    ///      helper here drives the meme market from then on.
    function _openMeme() private {
        vm.prank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.MEME, 18, address(1));
        market = _deployMarket(ICollateralPolicy.Tier.MEME);
        lens = new MarketLens(market);

        PoolKey memory key = _keyOf(tokenId);
        TierPresets.Preset memory preset = TierPresets.meme();
        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: preset.minPositionUsd
            })
        );

        vm.startPrank(borrower);
        IERC721(RobinhoodChain.POSITION_MANAGER).approve(address(market), tokenId);
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
    }

    /// @dev The fixture with fees donated into its pool, sized so this position's own share is
    ///      about `eth` wei and `usdgAmount` USDG, then aged underwater with a funded liquidator.
    ///      The fixture's natural ~$11 of fees sits far below any close-factor seizure, and the
    ///      paths where fees outrun the seizure need more than that.
    function _openWithDonatedFees(
        uint256 eth,
        uint256 usdgAmount
    ) private {
        _open(0);
        _fundLiquidator(2000e6);

        PoolKey memory key = _keyOf(tokenId);
        uint256 poolLiquidity = stateView.getLiquidity(key.toId());
        uint256 positionLiquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 ethDonation = eth * poolLiquidity / positionLiquidity;
        uint256 usdgDonation = usdgAmount * poolLiquidity / positionLiquidity;

        PoolDonateTest donor = new PoolDonateTest(poolManager);
        vm.deal(address(this), ethDonation);
        deal(address(usdg), address(this), usdgDonation);
        usdg.approve(address(donor), usdgDonation);
        donor.donate{value: ethDonation}(key, ethDonation, usdgDonation, "");

        _ageUntilHealthFactorBelow(1e18);
    }

    /// @dev What §8 step 5 does to this position's leftover fees, worked out from the valuation
    ///      alone with the library's own functions — not read back from a liquidation. Assumes
    ///      the fees outrun the seizure, so the slice pulls no liquidity and what arrives is
    ///      exactly the fee balance.
    function _expectedLeftover(
        IPositionValuer.Valuation memory v,
        uint256 repay,
        uint256 debt
    ) private view returns (uint256 appliedUsdg, uint256 cost, uint256 keptEth) {
        uint256 seizeUsd = DebtMath.debtUsd(repay, ONE_USD, RobinhoodChain.USDG_DECIMALS) * 10_500 / 10_000;
        keptEth = LiquidationMath.retainedFee(v.fees0, v.fees0, v.feesUsd, seizeUsd);
        appliedUsdg = Math.min(LiquidationMath.retainedFee(v.fees1, v.fees1, v.feesUsd, seizeUsd), debt - repay);
        (, cost) = LiquidationMath.purchase(
            keptEth,
            oracle.priceForLiquidation(Currency.wrap(RobinhoodChain.NATIVE)),
            18,
            ONE_USD,
            RobinhoodChain.USDG_DECIMALS,
            debt - repay - appliedUsdg
        );
    }

    /// @dev The liquidity a partial seizure of `repay` pulls (§8 step 5), from the valuation alone:
    ///      what the seizure is worth beyond the fees, as a share of principal. No haircut here.
    function _expectedSlice(
        uint256 repay
    ) private view returns (uint256) {
        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        uint256 seizeUsd = DebtMath.debtUsd(repay, ONE_USD, RobinhoodChain.USDG_DECIMALS) * 10_500 / 10_000;
        return Math.mulDiv(v.liquidity, seizeUsd - v.feesUsd, v.principalUsd);
    }

    /// @dev The USDG a borrower gets back once its USDG fees beyond the seizure outrun the rest of
    ///      the debt, from the valuation alone, at the partial close factor. Zero if they do not.
    function _expectedUsdgRefund() private view returns (uint256) {
        uint256 debt = market.debtOf(tokenId);
        uint256 repay = debt / 2;
        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        uint256 seizeUsd = DebtMath.debtUsd(repay, ONE_USD, RobinhoodChain.USDG_DECIMALS) * 10_500 / 10_000;
        uint256 kept = LiquidationMath.retainedFee(v.fees1, v.fees1, v.feesUsd, seizeUsd);
        return kept > debt - repay ? kept - (debt - repay) : 0;
    }

    function _ethWorth(
        uint256 usd
    ) private view returns (uint256) {
        return usd * 1e18 / oracle.priceForLiquidation(Currency.wrap(RobinhoodChain.NATIVE));
    }

    function _realizableUsd() private view returns (uint256) {
        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        return v.principalUsd + v.feesUsd;
    }

    /// @dev Moves the ETH price until the position's realizable value (§8 step 1, no haircut) sits
    ///      just above `targetUsd`. Bisection works because that value only rises with ETH.
    function _priceRealizableValueAt(
        uint256 targetUsd
    ) private {
        uint256 lo = 1e18;
        uint256 hi = ETH_AT_POOL_SPOT;
        for (uint256 i = 0; i < 128 && hi - lo > 1e6; ++i) {
            uint256 mid = (lo + hi) / 2;
            _dropEthPrice(mid);
            if (_realizableUsd() < targetUsd) lo = mid;
            else hi = mid;
        }
        _dropEthPrice(hi);
    }

    function _emitted(
        bytes32 topic
    ) private returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _fundLiquidator(
        uint256 amount
    ) private {
        deal(address(usdg), liquidator, amount);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    function _healthyGateHealthFactor() private returns (uint256 healthFactor) {
        vm.prank(liquidator);
        (bool succeeded, bytes memory reason) =
            address(market).call(abi.encodeCall(market.liquidate, (tokenId, type(uint256).max, 0, 0, liquidator)));
        assertFalse(succeeded, "the configured position must be healthy");
        assertEq(bytes4(reason), MarketLiquidation.PositionIsHealthy.selector, "unexpected gate refusal");
        healthFactor = _healthFactorFromReason(reason);
    }

    function _healthFactorFromReason(
        bytes memory reason
    ) private pure returns (uint256 healthFactor) {
        assembly {
            healthFactor := mload(add(reason, 68))
        }
    }

    /// @dev Lets accrued interest carry the position under `target`, which leaves the oracle
    ///      exactly where it was — on the pool's own price.
    function _ageUntilHealthFactorBelow(
        uint256 target
    ) private {
        for (uint256 i = 0; i < 4000; ++i) {
            if (lens.healthFactor(tokenId) < target) return;
            vm.warp(block.timestamp + 1 days);
            market.accrue();
        }
        revert("the health factor never fell far enough");
    }

    function _dropEthPrice(
        uint256 price
    ) private {
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), price, 18);
        oracle.set(Currency.wrap(RobinhoodChain.WETH), price, 18);
        market.accrue();
    }

    /// @dev USD 1e18 for a pair of raw amounts, at the prices liquidation reads.
    function _usdValue(
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint256) {
        return amount0 * oracle.priceForLiquidation(Currency.wrap(RobinhoodChain.NATIVE)) / 1e18 + amount1
            * oracle.priceForLiquidation(Currency.wrap(RobinhoodChain.USDG)) / 1e6;
    }

    /// @dev USD 1e18 for the fresh WETH/USDG hook pool, using the liquidation oracle directly.
    function _wethUsdgValue(
        uint256 wethAmount,
        uint256 usdgAmount
    ) private view returns (uint256) {
        return wethAmount * oracle.priceForLiquidation(Currency.wrap(RobinhoodChain.WETH)) / 1e18 + usdgAmount
            * oracle.priceForLiquidation(Currency.wrap(RobinhoodChain.USDG)) / 1e6;
    }

    /// @dev What a liquidation would pay out, without leaving it behind: run it, read it, undo
    ///      it. Used to write slippage minimums that are exactly on the boundary.
    function _previewSeizure(
        uint256 repayAmount
    ) private returns (uint256 out0, uint256 out1) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(liquidator);
        (, out0, out1,) = market.liquidate(tokenId, repayAmount, 0, 0, liquidator);
        vm.revertToState(snapshot);
    }

    function _socializedAmount() private returns (uint256 amount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("BadDebtSocialized(uint256)")) {
                return abi.decode(logs[i].data, (uint256));
            }
        }
        revert("BadDebtSocialized was never emitted");
    }
}
