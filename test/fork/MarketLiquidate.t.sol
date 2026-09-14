// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {MarketLiquidation} from "../../src/libraries/MarketLiquidation.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

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

        assertGt(market.healthFactor(tokenId), 1e18, "the fixture should start healthy");
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
    ///         no more, however much the caller offers.
    function test_blueChipClosesHalfWhileTheShortfallIsSmall() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);
        assertGt(market.healthFactor(tokenId), 0.9e18, "this test needs the partial close factor");

        uint256 debt = market.debtOf(tokenId);
        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(repaid, debt / 2, "half the debt, however much was offered");
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

    /* ------------------------------- the v0.2 gap ----------------------------- */

    /// @notice The regression that gave §8 step 5 its shape: a one-dollar repay against a
    ///         fee-rich position must not collect the position's whole fee balance.
    /// @dev A decrease realises every fee in the position no matter how little liquidity it
    ///      pulls, so the naive routing — `TAKE_PAIR` straight to the liquidator — hands over
    ///      ~$11 of fees for $1,05 of seizure. What must happen instead: the liquidator gets
    ///      fees worth `feeCredit` only, and the rest goes back to the borrower, USDG first
    ///      against their own debt.
    function test_aTinyRepayCannotDrainTheFeeBalance() public {
        _open(0);
        _fundLiquidator(1000e6);
        _ageUntilHealthFactorBelow(1e18);
        market.accrue();

        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        assertGt(v.feesUsd, 10e18, "the fixture should carry a fee balance worth taking");

        uint256 debtBefore = market.debtOf(tokenId);
        uint256 borrowerEthBefore = borrower.balance;

        vm.prank(liquidator);
        (uint256 repaid, uint256 out0, uint256 out1,) = market.liquidate(tokenId, 1e6, 0, 0, liquidator);

        assertLt(out0, v.fees0, "the liquidator must not receive the whole currency0 fee balance");
        assertLt(out1, v.fees1, "the liquidator must not receive the whole currency1 fee balance");
        assertApproxEqRel(_usdValue(out0, out1), 1.05e18, 0.02e18, "the payout is the seizure, not the fees");

        assertGt(repaid, 1e6, "the fees held back pay down the borrower's own debt");
        assertEq(market.debtOf(tokenId), debtBefore - repaid, "and the ledger says so");
        assertGt(borrower.balance, borrowerEthBefore, "the non-USDG remainder goes back to the borrower");
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
        assertGt(reservesBefore, market.reserveFloor(), "and part of it below the withdrawal floor");

        vm.recordLogs();
        vm.prank(liquidator);
        (uint256 repaid,,, uint256 badDebt) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        // The reserve the shortfall meets is what was there plus the fee this call just paid in.
        uint256 available = reservesBefore + repaid * 50 / 10_000;
        assertGt(badDebt, available, "the shortfall must outgrow the reserve here");
        assertEq(market.reserves(), 0, "the reserve is spent to the last unit, floor included");
        assertEq(_socializedAmount(), badDebt - available, "only the uncovered part reaches depositors");
    }

    /* --------------------------------- haircut -------------------------------- */

    /// @notice §6.3: a hook that skims on withdrawal lowers what the position is worth, and
    ///         §8 pays for it — this is the path where the haircut was still missing.
    /// @dev Read on the full-seizure branch, where the repay is exactly `value / (1 + bonus)`:
    ///      a 5% haircut has to show up as 5% less USDG changing hands for the same position.
    function test_theHaircutLowersWhatTheSeizureIsWorth() public {
        _open(500);
        _fundLiquidator(2000e6);
        _dropEthPrice(1200e18);

        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        uint256 realizable = (v.principalUsd + v.feesUsd) * 9500 / 10_000;

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);

        assertEq(repaid, realizable * 10_000 / 10_500 / 1e12, "the seizure pays for the haircut value, not the gross");
        assertApproxEqRel(
            repaid * 10_000 / 9500,
            (v.principalUsd + v.feesUsd) * 10_000 / 10_500 / 1e12,
            0.0001e18,
            "an unhaircut pool would have cost 5% more"
        );
    }

    /* ------------------------------ the price gates --------------------------- */

    /// @notice §5.2: every condition that blocks a borrow leaves liquidation running.
    /// @dev USDG outside [0,97; 1,03] and a pool far away from the oracle, both at once. The
    ///      third gate — a fresh Pyth quote more than 3% from Chainlink — belongs to FAR-20,
    ///      which is not on main yet; its own AC moved here because `liquidate` did not exist
    ///      when it was built, and it joins this test when the gate lands. What this already
    ///      proves is the structural half: nothing on the liquidation path reads the borrow
    ///      price surface, so no gate installed there can reach it.
    function test_liquidationOutlivesEveryBorrowPriceGate() public {
        _open(0);
        _fundLiquidator(2000e6);
        _ageUntilHealthFactorBelow(1e18);

        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.9e18, RobinhoodChain.USDG_DECIMALS);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.USDG), 0.9e18);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 80 / 100, 18);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 80 / 100);

        IPositionValuer.Valuation memory v = valuer.valueForLiquidation(tokenId);
        assertGt(v.spotDeviationBps, 200, "the pool must be outside the 2% borrow gate");

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, type(uint256).max, 0, 0, liquidator);
        assertGt(repaid, 0, "a liquidation must be possible when every borrow gate is shut");
    }

    /// @notice The liquidation price surface is the one §8 reads, and it is not the borrow one.
    /// @dev Split the two and the position is healthy on one and underwater on the other. A
    ///      `liquidate` that read `price` would refuse this call.
    function test_liquidationReadsItsOwnPriceSurface() public {
        _open(0);
        _fundLiquidator(2000e6);
        oracle.setLiquidationPrice(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT / 2);

        assertGt(market.healthFactor(tokenId), 1e18, "the borrow surface still calls it healthy");

        vm.prank(liquidator);
        (uint256 repaid,,,) = market.liquidate(tokenId, 10e6, 0, 0, liquidator);
        assertEq(repaid, 10e6, "the liquidation surface is what decides");
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
        (, uint256 out0, uint256 out1,) = market.liquidate(tokenId, repayAmount, 0, 0, liquidator);

        // What the liquidator actually paid against the debt: everything that left their
        // wallet, less the protocol fee, which is the only other thing reserves moved by.
        uint256 spent = walletBefore + out1 - usdg.balanceOf(liquidator);
        uint256 repay = spent - (market.reserves() - reservesBefore);

        assertLe(
            _usdValue(out0, out1), repay * 1e12 * 10_500 / 10_000 + 1e12, "the payout exceeded repay x (1 + bonus)"
        );
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
        uint256 amount = market.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
    }

    function _fundLiquidator(
        uint256 amount
    ) private {
        deal(address(usdg), liquidator, amount);
        vm.prank(liquidator);
        usdg.approve(address(market), type(uint256).max);
    }

    /// @dev Lets accrued interest carry the position under `target`, which leaves the oracle
    ///      exactly where it was — on the pool's own price.
    function _ageUntilHealthFactorBelow(
        uint256 target
    ) private {
        for (uint256 i = 0; i < 4000; ++i) {
            if (market.healthFactor(tokenId) < target) return;
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
