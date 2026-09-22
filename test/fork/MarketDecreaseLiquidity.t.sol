// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {ContractBorrower} from "../mocks/ContractBorrower.sol";
import {RedeemingRecipient} from "../mocks/RedeemingRecipient.sol";

/// @notice `decreaseLiquidity` (§4.1, FAR-8) against a real position on the pinned block.
/// @dev The main fixture is native ETH behind a live dynamic-fee hook and holds fees on both legs,
///      so the ETH leg, the hook running inside the removal, and the fees that leave with the
///      principal are all exercised by the same position.
///
///      What a removal should pay and leave behind is never recomputed here. `_probe` makes the
///      same removal straight on PositionManager, as the market (which owns the NFT), with a
///      plain `TAKE_PAIR`, reads the result, and rolls the chain back. The market's own path is then
///      held to those figures.
contract MarketDecreaseLiquidityForkTest is MarketForkTest {
    /// @dev What `_probe` found: what the removal pays, and the position it leaves.
    struct Probe {
        uint256 out0;
        uint256 out1;
        uint256 principalUsdLeft;
        uint256 positionValueLeft;
        uint256 healthFactorLeft;
    }

    /// @dev The blue-chip preset's borrow limit, which every listing here uses.
    uint256 internal constant MAX_LTV_BPS = 6500;

    address internal lender = address(0x1E4DE2);
    address internal recipient = makeAddr("recipient");

    uint256 internal tokenId;
    address internal borrower;
    uint128 internal liquidity;

    /// @dev Held rather than read through `market.asset()` inside a pranked statement, where the
    ///      external call would spend the prank.
    IERC20 internal usdg;

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        borrower = nft.ownerOf(tokenId);
        liquidity = positionManager.getPositionLiquidity(tokenId);
        usdg = IERC20(market.asset());
    }

    /* -------------------------------- the removal ----------------------------- */

    /// @notice With nothing owed, half the liquidity leaves as its principal plus every fee, and half
    ///         stays.
    /// @dev Both legs come straight from PoolManager, so neither the market's ETH nor its USDG may
    ///      move: `rescueUnaccountedEth` sweeps whatever ETH is there, and is only sound while no
    ///      path leaves any behind.
    function test_halfThePrincipalAndEveryFeeReachTheRecipient() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        assertGt(before.fees0, 0, "the fixture must hold ETH fees");
        assertGt(before.fees1, 0, "the fixture must hold USDG fees");
        uint128 half = liquidity / 2;
        Probe memory expected = _probe(tokenId, half);
        uint256 marketEth = address(market).balance;
        uint256 marketUsdg = usdg.balanceOf(address(market));

        // FAR-52: the fees that leave with the slice are reported first, as `collectFees` reports them.
        vm.expectEmit(true, true, false, true, address(market));
        emit FarmentaMarket.CollectFees(tokenId, _keyOf(tokenId).toId(), before.fees0, before.fees1);
        vm.expectEmit(true, true, false, true, address(market));
        emit FarmentaMarket.LiquidityChanged(tokenId, _keyOf(tokenId).toId(), -int256(uint256(half)));
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, half, 0, 0, recipient);

        assertEq(recipient.balance, expected.out0, "the ETH leg reaches the recipient");
        assertEq(usdg.balanceOf(recipient), expected.out1, "the USDG leg reaches the recipient");
        assertApproxEqRel(recipient.balance - before.fees0, before.amount0 / 2, 0.01e18, "half the ETH principal");
        assertApproxEqRel(
            usdg.balanceOf(recipient) - before.fees1, before.amount1 / 2, 0.01e18, "half the USDG principal"
        );

        IPositionValuer.Valuation memory left = valuer.value(tokenId);
        assertEq(left.liquidity, liquidity - half, "the other half stays");
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - half, "in PositionManager's books too");
        assertEq(left.fees0, 0, "every ETH fee left with the principal");
        assertEq(left.fees1, 0, "every USDG fee left with the principal");
        assertEq(address(market).balance, marketEth, "no ETH is left in the market");
        assertEq(usdg.balanceOf(address(market)), marketUsdg, "the removal never touches the market's cash");
        assertEq(nft.ownerOf(tokenId), address(market), "the position stays in custody");
    }

    /// @notice An ERC-20 pair pays both legs to `to` the same way.
    function test_bothErc20LegsReachTheRecipient() public {
        uint256 id = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        address holder = _deposit(id);
        uint128 half = positionManager.getPositionLiquidity(id) / 2;
        Probe memory expected = _probe(id, half);
        assertGt(expected.out0, 0, "the fixture must pay a WETH leg");
        assertGt(expected.out1, 0, "the fixture must pay a USDG leg");

        vm.prank(holder);
        market.decreaseLiquidity(id, half, 0, 0, recipient);

        assertEq(IERC20(RobinhoodChain.WETH).balanceOf(recipient), expected.out0, "the WETH leg reaches the recipient");
        assertEq(usdg.balanceOf(recipient), expected.out1, "the USDG leg reaches the recipient");
    }

    /// @notice Only the depositor may remove liquidity, and a refusal leaves the position whole.
    function test_onlyTheDepositorMayRemove() public {
        _deposit(tokenId);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotTheDepositor.selector, tokenId, borrower));
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, 0, stranger);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "the liquidity stays in the position");
    }

    /// @notice §4.1 v0.43: PositionManager is refused as a recipient. A payout made to it would sit in
    ///         its balance, where anyone takes it with `SWEEP`.
    function test_positionManagerIsRefusedAsTheRecipient() public {
        _deposit(tokenId);
        address pm = address(positionManager);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, pm));
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, 0, pm);
    }

    /// @notice Asking for more than the position holds is refused by name, not deep inside PoolManager.
    function test_moreThanThePositionHoldsIsRefusedByName() public {
        _deposit(tokenId);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.LiquidityExceedsPosition.selector, tokenId, liquidity + 1, liquidity)
        );
        market.decreaseLiquidity(tokenId, liquidity + 1, 0, 0, recipient);
    }

    /// @notice §6.5: freezing a pool stops new risk, not a borrower taking its own liquidity out.
    /// @dev With debt outstanding, so the health check and its price gates run on a frozen pool too.
    function test_freezingThePoolDoesNotStopTheRemoval() public {
        _openLoan(20e6);
        // Read before the prank: `_keyOf` is an external call and would spend it.
        PoolId poolId = _keyOf(tokenId).toId();
        vm.prank(owner);
        policy.setFrozen(poolId, true);
        Probe memory expected = _probe(tokenId, liquidity / 4);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);

        assertEq(usdg.balanceOf(recipient), expected.out1, "a frozen pool's liquidity can still be removed");
    }

    /* --------------------------------- slippage ------------------------------- */

    /// @notice A minimum the pool meets, to the unit, passes.
    /// @dev The minimums are the slice's principal: what the probe paid, less the fees that came with
    ///      it.
    function test_aMinimumThePoolMeetsExactlyPasses() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        Probe memory expected = _probe(tokenId, liquidity / 2);
        uint128 principal0 = uint128(expected.out0 - before.fees0);
        uint128 principal1 = uint128(expected.out1 - before.fees1);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 2, principal0, principal1, recipient);

        assertEq(recipient.balance, expected.out0, "the removal went through");
    }

    /// @notice A minimum one unit above what the pool returns reverts, and the fees paid out alongside
    ///         do not make up the difference.
    /// @dev PositionManager holds the minimums against the principal alone. The fixture's fees are far
    ///      more than one unit on either leg, so a check that counted them would let both of these
    ///      through.
    function test_aMinimumAboveThePrincipalRevertsWhateverTheFees() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        Probe memory expected = _probe(tokenId, liquidity / 2);
        uint128 principal0 = uint128(expected.out0 - before.fees0);
        uint128 principal1 = uint128(expected.out1 - before.fees1);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, principal0 + 1, principal0)
        );
        market.decreaseLiquidity(tokenId, liquidity / 2, principal0 + 1, 0, recipient);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, principal1 + 1, principal1)
        );
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, principal1 + 1, recipient);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "the liquidity stays in the position");
    }

    /* ------------------------------ minimum position -------------------------- */

    /// @notice §6.1 on what stays: a remainder under the pool's minimum is refused, one at it is not.
    /// @dev Owing nothing, which is the case the ticket left open: the floor holds for as long as the
    ///      position is in custody (decided 17 Sep 2026), because `borrow` never looks at it again.
    function test_whatStaysMustStillClearTheMinimumEvenWithNoDebt() public {
        _deposit(tokenId);
        uint256 principalUsd = valuer.value(tokenId).principalUsd;
        uint128 tooMuch = liquidity - uint128(uint256(liquidity) * 49.5e18 / principalUsd);
        uint128 justEnough = liquidity - uint128(uint256(liquidity) * 50.5e18 / principalUsd);
        uint256 left = _probe(tokenId, tooMuch).principalUsdLeft;
        assertLt(left, 50e18, "the larger removal must leave less than the minimum");

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, left, 50e18));
        market.decreaseLiquidity(tokenId, tooMuch, 0, 0, recipient);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, justEnough, 0, 0, recipient);
        assertGe(valuer.value(tokenId).principalUsd, 50e18, "what stays clears the minimum");
    }

    /// @notice The minimum binds to the unit: a remainder worth exactly the minimum stays, and a minimum
    ///         one unit higher refuses the same removal.
    /// @dev The pool is listed with the minimum set to what the probed removal leaves, which is the
    ///      only way to land on the boundary itself rather than near it.
    function test_theMinimumBindsToTheUnit() public {
        uint128 half = liquidity / 2;
        uint256 snapshot = vm.snapshotState();
        _deposit(tokenId);
        uint256 left = _probe(tokenId, half).principalUsdLeft;
        vm.revertToState(snapshot);

        _depositListed(tokenId, uint128(left), 0);
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, half, 0, 0, recipient);
        assertEq(valuer.value(tokenId).principalUsd, left, "exactly the minimum stays");
        vm.revertToState(snapshot);

        _depositListed(tokenId, uint128(left + 1), 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, left, left + 1));
        market.decreaseLiquidity(tokenId, half, 0, 0, recipient);
    }

    /// @notice The minimum holds with debt outstanding too, and is what a removal failing both checks
    ///         reports.
    /// @dev First a debt small enough that about $45 of principal still covers it, so the minimum is
    ///      the only thing in the way. Then one that the remainder cannot carry either: the minimum is
    ///      checked first, and names itself.
    function test_theMinimumHoldsWithDebtAndIsCheckedBeforeTheLimit() public {
        _openLoan(10e6);
        uint256 principalUsd = valuer.value(tokenId).principalUsd;
        uint128 tooMuch = liquidity - uint128(uint256(liquidity) * 45e18 / principalUsd);
        Probe memory expected = _probe(tokenId, tooMuch);
        assertLe(_usd(market.debtOf(tokenId)), _limit(expected, MAX_LTV_BPS), "the debt must still fit what stays");

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, expected.principalUsdLeft, 50e18)
        );
        market.decreaseLiquidity(tokenId, tooMuch, 0, 0, recipient);

        vm.prank(borrower);
        market.borrow(tokenId, 90e6, borrower);
        assertGt(_usd(market.debtOf(tokenId)), _limit(expected, MAX_LTV_BPS), "now the debt does not fit either");
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, expected.principalUsdLeft, 50e18)
        );
        market.decreaseLiquidity(tokenId, tooMuch, 0, 0, recipient);
    }

    /// @notice Fees do not count towards the minimum (§6.1 v0.6): they can be claimed a second later.
    /// @dev The position is given fees worth several times the minimum. They leave with the removal
    ///      anyway, and the floor is measured on the principal that stays.
    function test_unclaimedFeesDoNotCoverTheMinimum() public {
        _deposit(tokenId);
        _donateFees(tokenId, 0, 200e6);
        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertGt(v.feesUsd, 150e18, "the donation must reach the position");
        uint128 tooMuch = liquidity - uint128(uint256(liquidity) * 40e18 / v.principalUsd);

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.PositionBelowMinimum.selector);
        market.decreaseLiquidity(tokenId, tooMuch, 0, 0, recipient);
    }

    /// @notice The whole position never leaves this way: nothing would be left to hold as collateral.
    /// @dev A borrower owing nothing takes the NFT back with `withdrawCollateral` instead.
    function test_removingEverythingIsRefused() public {
        _deposit(tokenId);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, 0, 50e18));
        market.decreaseLiquidity(tokenId, liquidity, 0, 0, recipient);
    }

    /// @notice The minimum remaining position is measured after the permitted hook's haircut.
    function test_theMinimumIsMeasuredAfterTheRemovalHaircut() public {
        _useRemovalHaircutFixture(1000);
        uint256 principal = valuer.value(tokenId).principalUsd;
        uint128 amount = liquidity - uint128(uint256(liquidity) * 51e18 / principal);
        _depositListed(tokenId, 50e18, 1000);
        uint256 rawLeft = _probe(tokenId, amount).principalUsdLeft;
        assertLt(rawLeft * 90 / 100, 50e18, "the hook haircut must put the remainder below the floor");

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.PositionBelowMinimum.selector, rawLeft * 90 / 100, uint256(50e18))
        );
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
    }

    /* -------------------------------- borrow limit ---------------------------- */

    /// @notice The borrow limit after a removal uses the hook-reduced collateral value.
    function test_theBorrowLimitCountsTheRemovalHaircut() public {
        _useRemovalHaircutFixture(1000);
        uint128 amount = liquidity / 4;
        uint256 snapshot = vm.snapshotState();
        _deposit(tokenId);
        uint256 rawLimit = _limit(_probe(tokenId, amount), MAX_LTV_BPS);
        vm.revertToState(snapshot);

        _depositListed(tokenId, 50e18, 1000);
        uint256 haircutLimit = _limit(_probe(tokenId, amount), MAX_LTV_BPS);
        assertEq(haircutLimit, rawLimit * 90 / 100, "the haircut must reduce the removal limit");
        uint256 debt = (rawLimit + haircutLimit) / 2 / 1e12;

        _lend(300e6);
        vm.prank(borrower);
        market.borrow(tokenId, debt, borrower);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.RemovalExceedsBorrowLimit.selector, tokenId, _usd(debt), haircutLimit)
        );
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
    }

    /// @notice An indebted removal that leaves the debt within the borrow limit goes through, and the
    ///         debt is untouched.
    function test_anIndebtedRemovalWithinTheBorrowLimitSucceeds() public {
        _openLoan(100e6);
        uint256 debt = market.debtOf(tokenId);
        uint128 quarter = liquidity / 4;
        Probe memory expected = _probe(tokenId, quarter);
        assertLe(_usd(debt), _limit(expected, MAX_LTV_BPS), "the removal must stay within the borrow limit");

        vm.expectEmit(true, true, false, true, address(market));
        emit FarmentaMarket.LiquidityChanged(tokenId, _keyOf(tokenId).toId(), -int256(uint256(quarter)));
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, quarter, 0, 0, recipient);

        assertEq(usdg.balanceOf(recipient), expected.out1, "the USDG leg reaches the recipient");
        assertEq(market.debtOf(tokenId), debt, "the removal does not touch the debt");
        assertEq(lens.positionValue(tokenId), expected.positionValueLeft, "and the position is worth what was probed");
    }

    /// @notice §4.1 v0.59: the debt must fit `maxLtvBps` of what is left, to the unit.
    /// @dev The removal is fixed and the debt is set against it. The borrow limit of what the removal
    ///      leaves comes from the probe; a debt of exactly that (rounded down to a USDG unit) passes,
    ///      and one unit more is refused with both figures in the error.
    function test_theBorrowLimitOfWhatIsLeftBindsToTheUnit() public {
        _deposit(tokenId);
        _lend(300e6);
        uint128 amount = liquidity / 4;
        uint256 limitUsd = _limit(_probe(tokenId, amount), MAX_LTV_BPS);
        uint256 debt = limitUsd / 1e12;
        uint256 snapshot = vm.snapshotState();

        vm.prank(borrower);
        market.borrow(tokenId, debt, borrower);
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - amount, "at the limit it goes through");
        vm.revertToState(snapshot);

        vm.prank(borrower);
        market.borrow(tokenId, debt + 1, borrower);
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.RemovalExceedsBorrowLimit.selector, tokenId, _usd(debt + 1), limitUsd)
        );
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
    }

    /// @notice Borrowed to `maxLtvBps`, a position has no liquidity to spare: a health factor of 1 is
    ///         not the bar (§15 no. 22).
    /// @dev The removal is a thousandth of the position. It leaves the health factor near LT/LTV,
    ///      about 1.15, which the rule before v0.59 accepted; two calls then reached a loan-to-value
    ///      `borrow` refuses.
    function test_borrowedToTheLimitNothingCanBeRemoved() public {
        _deposit(tokenId);
        _lend(300e6);
        uint256 limit = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, limit, borrower);
        uint128 amount = liquidity / 1000;
        Probe memory expected = _probe(tokenId, amount);
        assertGe(expected.healthFactorLeft, 1.1e18, "the position stays far from liquidation");

        // Read before the prank: `debtOf` is an external call and would spend it.
        uint256 debtUsd = _usd(market.debtOf(tokenId));
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                FarmentaMarket.RemovalExceedsBorrowLimit.selector, tokenId, debtUsd, _limit(expected, MAX_LTV_BPS)
            )
        );
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "the liquidity stays in the position");
        assertEq(usdg.balanceOf(recipient), 0, "and nothing reached the recipient");
    }

    /// @notice A position already over its borrow limit, but healthy, removes nothing until it repays,
    ///         while its fee claim still goes through.
    /// @dev ETH falls 1.5%, inside the 2% spot gate, which carries a loan borrowed to the limit just
    ///      past it. `collectFees` keeps `HF >= 1` (v0.40): between `maxLtvBps` and LT it still pays.
    function test_overTheBorrowLimitButHealthyRemovesNothingAndStillClaims() public {
        _deposit(tokenId);
        _lend(300e6);
        uint256 limit = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, limit, borrower);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 985 / 1000, 18);
        assertEq(lens.maxBorrow(tokenId), 0, "the loan must be over its borrow limit");
        assertGe(lens.healthFactor(tokenId), 1.1e18, "and still far from liquidation");

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.RemovalExceedsBorrowLimit.selector);
        market.decreaseLiquidity(tokenId, liquidity / 1000, 0, 0, recipient);

        uint256 fees1 = valuer.value(tokenId).fees1;
        vm.prank(borrower);
        market.collectFees(tokenId, recipient);
        assertEq(usdg.balanceOf(recipient), fees1, "the fee claim is held to HF >= 1, and passes");
    }

    /// @notice §6.5: on a frozen pool ramped under its borrow limit, the liquidation threshold is what
    ///         binds, so a removal never leaves a position that can be liquidated at once.
    /// @dev LT is ramped to 50% against a `maxLtvBps` of 65%. A debt between the two limits of what
    ///      the removal leaves is refused at the 50% figure; one under both goes through.
    function test_onAFrozenPoolRampedUnderMaxLtvTheThresholdBinds() public {
        _deposit(tokenId);
        _lend(300e6);
        uint128 amount = liquidity / 4;
        Probe memory expected = _probe(tokenId, amount);
        uint256 snapshot = vm.snapshotState();

        _borrowThenRampTo5000((_limit(expected, 5000) + _limit(expected, MAX_LTV_BPS)) / 2 / 1e12);
        // Read before the prank: `debtOf` is an external call and would spend it.
        uint256 debtUsd = _usd(market.debtOf(tokenId));
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                FarmentaMarket.RemovalExceedsBorrowLimit.selector, tokenId, debtUsd, _limit(expected, 5000)
            )
        );
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
        vm.revertToState(snapshot);

        _borrowThenRampTo5000(_limit(expected, 5000) / 1e12 * 99 / 100);
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - amount, "under both limits it goes through");
    }

    /// @notice §7: the removal accrues before it checks the limit, so interest nobody has accrued yet
    ///         still counts against it.
    /// @dev The debt is set 0.1% under the limit the removal leaves. Sixty days then pass with nothing
    ///      accrued: at the stored index the debt still fits, at the accrued one it does not. The
    ///      lender's cash is nearly all lent out, so the curve accrues at a rate that matters.
    function test_theRemovalAccruesBeforeItChecksTheLimit() public {
        _deposit(tokenId);
        uint128 amount = liquidity / 4;
        uint256 limitUsd = _limit(_probe(tokenId, amount), MAX_LTV_BPS);
        uint256 debt = limitUsd / 1e12 * 999 / 1000;
        _lend(debt + 1e6);
        vm.prank(borrower);
        market.borrow(tokenId, debt, borrower);

        vm.warp(block.timestamp + 60 days);
        assertLe(_usd(market.debtOf(tokenId)), limitUsd, "at the stored index the removal must pass");

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.RemovalExceedsBorrowLimit.selector);
        market.decreaseLiquidity(tokenId, amount, 0, 0, recipient);
    }

    /// @notice Whatever is asked for, a removal that goes through leaves the debt within the borrow
    ///         limit and the position over the minimum, and one that does not go through was refused
    ///         for one of those two reasons and moved nothing.
    function testFuzz_aRemovalThatSucceedsLeavesTheDebtWithinTheLimit(
        uint128 amount,
        uint256 debt
    ) public {
        _deposit(tokenId);
        _lend(300e6);
        debt = bound(debt, 10e6, lens.maxBorrow(tokenId));
        vm.prank(borrower);
        market.borrow(tokenId, debt, borrower);
        amount = uint128(bound(amount, 1, liquidity));

        vm.prank(borrower);
        try market.decreaseLiquidity(tokenId, amount, 0, 0, recipient) {
            assertLe(
                _usd(debt), lens.positionValue(tokenId) * MAX_LTV_BPS / 10_000, "a removal left the debt over the limit"
            );
            assertGe(valuer.value(tokenId).principalUsd, 50e18, "or the position under the minimum");
            assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - amount, "exactly `amount` left");
            assertEq(market.debtOf(tokenId), debt, "the debt is untouched");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == FarmentaMarket.PositionBelowMinimum.selector
                    || selector == FarmentaMarket.RemovalExceedsBorrowLimit.selector,
                "a removal was refused for a reason that is neither the minimum nor the limit"
            );
            assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "a refused removal took liquidity");
            assertEq(usdg.balanceOf(recipient), 0, "or paid the recipient");
        }
    }

    /* --------------------------------- price gates ---------------------------- */

    /// @notice §5.2: with debt outstanding, a USDG price outside [0,97; 1,03] refuses the removal.
    function test_anIndebtedRemovalRunsTheUsdgBand() public {
        _openLoan(20e6);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UsdgPriceOutOfBounds.selector, 0.96e18));
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);
    }

    /// @notice §5.2: with debt outstanding, a pool more than 2% from the oracle refuses it.
    /// @dev A 3% move keeps the health factor far above 1, so the refusal can only be the gate.
    function test_anIndebtedRemovalRunsTheSpotGate() public {
        _openLoan(20e6);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 97 / 100, 18);
        assertGt(valuer.value(tokenId).spotDeviationBps, 200, "the pool must be outside the 2% gate");

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.SpotPriceDeviation.selector);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);
    }

    /// @notice With nothing owed there is no debt to protect, so none of the gates apply.
    function test_aRemovalWithNoDebtRunsNoPriceGate() public {
        _deposit(tokenId);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 97 / 100, 18);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - liquidity / 4, "the removal went through");
    }

    /* --------------------------------- meme market ---------------------------- */

    /// @notice §5.3: every market transaction touching a meme pool records an observation first, and a
    ///         removal is one of them.
    function test_aMemeRemovalRecordsAnObservationFirst() public {
        FarmentaMarket memeMarket = _openMemeMarket();
        PoolId poolId = _keyOf(tokenId).toId();
        uint256 records = oracle.recordCount(poolId);
        oracle.watch(positionManager, tokenId);

        vm.expectEmit(true, true, false, true, address(memeMarket));
        emit FarmentaMarket.LiquidityChanged(tokenId, poolId, -int256(uint256(liquidity / 4)));
        vm.prank(borrower);
        memeMarket.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);

        assertEq(oracle.recordCount(poolId), records + 1, "the removal recorded the pool once");
        assertEq(oracle.liquidityOnLastRecord(), liquidity, "and did so before any liquidity had left");
    }

    /// @notice A blue-chip removal has no TWAP to feed, and pays nothing for one.
    function test_aBlueChipRemovalRecordsNothing() public {
        _deposit(tokenId);
        PoolId poolId = _keyOf(tokenId).toId();

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);

        assertEq(oracle.recordCount(poolId), 0, "no observation for a blue-chip pool");
    }

    /// @notice §5.2 on a meme market: the ±2% spot gate is a blue-chip rule, so it does not hold up an
    ///         indebted removal there, while the USDG band still does.
    function test_anIndebtedMemeRemovalRunsTheMemeGates() public {
        FarmentaMarket memeMarket = _openMemeMarket();
        vm.prank(borrower);
        memeMarket.borrow(tokenId, 10e6, borrower);

        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 95 / 100, 18);
        assertGt(valuer.value(tokenId).spotDeviationBps, 200, "the pool must be outside the blue-chip spot gate");

        vm.prank(borrower);
        memeMarket.decreaseLiquidity(tokenId, liquidity / 8, 0, 0, recipient);
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - liquidity / 8, "the removal went through");

        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UsdgPriceOutOfBounds.selector, 0.96e18));
        memeMarket.decreaseLiquidity(tokenId, liquidity / 8, 0, 0, recipient);
    }

    /* ------------------------------ outbound calls ---------------------------- */

    /// @notice §4.1 v0.26: the borrow asset leaves before any other leg, so a native-ETH recipient
    ///         already holds its USDG when its code first runs.
    /// @dev `TAKE_PAIR` pays `currency0` first, and in this pool that is the ETH: under it the
    ///      recipient would see no USDG at all.
    function test_theUsdgLegLeavesBeforeTheEth() public {
        _deposit(tokenId);
        Probe memory expected = _probe(tokenId, liquidity / 2);
        RedeemingRecipient receiver = new RedeemingRecipient(market);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, 0, address(receiver));

        assertEq(receiver.usdgOnEthArrival(), expected.out1, "the USDG leg was already there when the ETH arrived");
        assertEq(address(receiver).balance, expected.out0, "and the ETH leg arrived in full");
    }

    /// @notice §4.1 v0.26: a vault redeem made from inside the removal's ETH payout is priced exactly
    ///         as one made after the removal.
    /// @dev Thirty days of interest are left unaccrued, so the redeem inside the payout is the first
    ///      thing to see them unless the removal's own accrual already has. The removal moves no
    ///      cash, debt or reserve, so there is no half-written ledger for the redeem to read; this
    ///      pins that down for the day `decreaseLiquidity` starts writing anything more.
    function test_aRedeemFromInsideTheRemovalGainsNothing() public {
        _openLoan(100e6);
        RedeemingRecipient attacker = new RedeemingRecipient(market);
        deal(address(usdg), address(attacker), 100e6);
        attacker.deposit(100e6);
        vm.warp(block.timestamp + 30 days);

        uint256 shares = market.balanceOf(address(attacker));
        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);
        uint256 fair = market.previewRedeem(shares);
        vm.revertToState(snapshot);

        attacker.arm();
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, address(attacker));

        assertGt(attacker.redeemed(), 0, "the redeem must actually run inside the payout");
        assertEq(attacker.redeemed(), fair, "a share redeemed mid-removal is worth what it is worth after");
    }

    /// @notice §4.1 v0.26: the accrual, the removal's only write, is done before the first outbound call.
    /// @dev Thirty days of interest are left unaccrued. The recipient reads the market's borrow index
    ///      from inside the ETH payout: an index still at its old value there means the ledger was
    ///      written after code the market does not control had already run. The redeem test above
    ///      cannot see this, because `redeem` accrues for itself.
    function test_theLedgerIsAccruedBeforeTheFirstOutboundCall() public {
        _openLoan(100e6);
        RedeemingRecipient receiver = new RedeemingRecipient(market);
        uint256 staleIndex = market.borrowIndex();
        vm.warp(block.timestamp + 30 days);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, address(receiver));

        assertGt(market.borrowIndex(), staleIndex, "thirty days must move the index");
        assertEq(receiver.borrowIndexOnEthArrival(), market.borrowIndex(), "the index was current when the ETH arrived");
    }

    /// @notice A recipient that calls back into the market from the ETH it is paid gets nowhere, and
    ///         takes the removal down with it.
    /// @dev The guard on the wrapper. `repay` of zero is the call the recipient makes, which succeeds
    ///      if the guard is gone. The ETH transfer reverting is what PoolManager reports.
    function test_aReentrantRecipientIsRefused() public {
        _deposit(tokenId);
        ContractBorrower receiver = new ContractBorrower(market);
        receiver.armReentry(tokenId);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(receiver),
                bytes4(0),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
                abi.encodeWithSelector(CurrencyLibrary.NativeTransferFailed.selector)
            )
        );
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, 0, address(receiver));
    }

    /* --------------------------------- helpers -------------------------------- */

    function _deposit(
        uint256 id
    ) private returns (address holder) {
        return _depositListed(id, 50e18, 0);
    }

    function _useRemovalHaircutFixture(
        uint16 haircutBps
    ) private {
        tokenId = _mintRemovalHaircutPosition(haircutBps, 1e14);
        borrower = address(this);
        liquidity = positionManager.getPositionLiquidity(tokenId);
    }

    function _depositListed(
        uint256 id,
        uint128 minPositionUsd,
        uint16 removeHaircutBps
    ) private returns (address holder) {
        _listPoolOf(id, minPositionUsd, removeHaircutBps);
        holder = nft.ownerOf(id);
        vm.startPrank(holder);
        nft.approve(address(market), id);
        market.depositCollateral(id);
        vm.stopPrank();
    }

    function _lend(
        uint256 amount
    ) private {
        deal(address(usdg), lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(amount, lender);
        vm.stopPrank();
    }

    function _openLoan(
        uint256 amount
    ) private {
        _deposit(tokenId);
        _lend(300e6);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
    }

    /// @dev A USDG amount in USD 1e18, at the fixture's USDG price of exactly one dollar.
    function _usd(
        uint256 debt
    ) private pure returns (uint256) {
        return debt * 1e12;
    }

    /// @dev The debt, in USD 1e18, that `bps` of what the probed removal leaves allows.
    function _limit(
        Probe memory probe,
        uint256 bps
    ) private pure returns (uint256) {
        return probe.positionValueLeft * bps / 10_000;
    }

    /// @dev Borrows `amount`, then freezes the pool and ramps its threshold to 50% over a day, under
    ///      the 65% borrow limit, and lets the day pass. The ledger is accrued at the end so that
    ///      `debtOf` is the figure the next call in the same block will see.
    function _borrowThenRampTo5000(
        uint256 amount
    ) private {
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        PoolId poolId = _keyOf(tokenId).toId();
        vm.startPrank(owner);
        policy.setFrozen(poolId, true);
        policy.scheduleLtRamp(poolId, 5000, uint40(block.timestamp), 1 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        market.accrue();
        assertEq(policy.termsOf(poolId).ltBps, 5000, "the ramp must have landed");
    }

    /// @dev Removes `amount` from `id` straight on PositionManager, as the market that owns it, and
    ///      reports what that paid and left behind. The chain is rolled back afterwards. It shares no
    ///      code with the market's path: a `TAKE_PAIR` to a fresh address, and the lens for the
    ///      collateral value and the health factor.
    function _probe(
        uint256 id,
        uint128 amount
    ) private returns (Probe memory probe) {
        PoolKey memory key = _keyOf(id);
        address sink = makeAddr("probe");
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(amount), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, sink);
        bytes memory call_ =
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);

        uint256 snapshot = vm.snapshotState();
        vm.prank(address(market));
        positionManager.modifyLiquidities(call_, block.timestamp);
        probe.out0 = key.currency0.balanceOf(sink);
        probe.out1 = key.currency1.balanceOf(sink);
        probe.principalUsdLeft = valuer.value(id).principalUsd;
        probe.positionValueLeft = lens.positionValue(id);
        probe.healthFactorLeft = lens.healthFactor(id);
        vm.revertToState(snapshot);
    }

    /// @dev Donates to the position's pool so that `id`'s own share is about `amount0` and
    ///      `amount1`. Each leg is scaled by the pool's liquidity over the position's.
    function _donateFees(
        uint256 id,
        uint256 amount0,
        uint256 amount1
    ) private {
        PoolKey memory key = _keyOf(id);
        uint256 poolLiquidity = stateView.getLiquidity(key.toId());
        uint256 positionLiquidity = positionManager.getPositionLiquidity(id);
        uint256 donation0 = amount0 * poolLiquidity / positionLiquidity;
        uint256 donation1 = amount1 * poolLiquidity / positionLiquidity;

        PoolDonateTest donor = new PoolDonateTest(poolManager);
        uint256 value;
        if (key.currency0.isAddressZero()) {
            value = donation0;
            vm.deal(address(this), donation0);
        } else {
            deal(Currency.unwrap(key.currency0), address(this), donation0);
            IERC20(Currency.unwrap(key.currency0)).approve(address(donor), donation0);
        }
        deal(Currency.unwrap(key.currency1), address(this), donation1);
        IERC20(Currency.unwrap(key.currency1)).approve(address(donor), donation1);
        donor.donate{value: value}(key, donation0, donation1, "");
    }

    /// @dev The fixture listed and deposited on a meme market, with a lender behind it. Native ETH is
    ///      re-tiered as meme first, which makes the pool meme (§6.1 takes the higher tier).
    function _openMemeMarket() private returns (FarmentaMarket memeMarket) {
        vm.prank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.MEME, 18, address(1));
        memeMarket = _deployMarket(ICollateralPolicy.Tier.MEME);

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
                minPositionUsd: 50e18
            })
        );

        vm.startPrank(borrower);
        nft.approve(address(memeMarket), tokenId);
        memeMarket.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(usdg), lender, 300e6);
        vm.startPrank(lender);
        usdg.approve(address(memeMarket), type(uint256).max);
        memeMarket.deposit(300e6, lender);
        vm.stopPrank();
    }
}
