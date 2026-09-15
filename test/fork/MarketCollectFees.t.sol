// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {MarketLedger} from "../../src/libraries/MarketLedger.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {RedeemingRecipient} from "../mocks/RedeemingRecipient.sol";

/// @notice `collectFees` (§4.1, FAR-7) against a real position with real fees on the pinned block.
/// @dev The main fixture is native ETH behind a live dynamic-fee hook, so the ETH leg, the hook
///      running inside the claim, and a USDG leg are all exercised by the same position.
contract MarketCollectFeesForkTest is MarketForkTest {
    address internal lender = address(0x1E4DE2);
    address internal recipient = makeAddr("recipient");

    uint256 internal tokenId;
    address internal borrower;

    /// @dev Held rather than read through `market.asset()` inside a pranked statement, where the
    ///      external call would spend the prank.
    IERC20 internal usdg;

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        borrower = nft.ownerOf(tokenId);
        usdg = IERC20(market.asset());
    }

    /* --------------------------------- the claim ------------------------------ */

    /// @notice With nothing owed, every fee reaches `to` and the principal stays exactly where it was.
    /// @dev The ETH leg comes straight from PoolManager, so the market's own ETH balance must not
    ///      move: `rescueUnaccountedEth` sweeps whatever is there, and is only sound while no path
    ///      leaves ETH behind.
    function test_everyFeeReachesTheRecipientAndThePrincipalStays() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        assertGt(before.fees0, 0, "the fixture must hold ETH fees");
        assertGt(before.fees1, 0, "the fixture must hold USDG fees");
        uint256 marketEth = address(market).balance;
        uint256 marketUsdg = usdg.balanceOf(address(market));

        vm.expectEmit(true, true, false, true, address(market));
        emit FarmentaMarket.CollectFees(tokenId, _keyOf(tokenId).toId(), before.fees0, before.fees1);
        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(recipient.balance, before.fees0, "the ETH fees reach the recipient");
        assertEq(usdg.balanceOf(recipient), before.fees1, "the USDG fees reach the recipient");
        _assertOnlyTheFeesLeft(tokenId, before);
        assertEq(address(market).balance, marketEth, "no ETH is left in the market");
        assertEq(usdg.balanceOf(address(market)), marketUsdg, "the claim never touches the market's cash");
        assertEq(nft.ownerOf(tokenId), address(market), "the position stays in custody");
    }

    /// @notice An ERC-20 pair pays both legs to `to` the same way.
    function test_bothErc20LegsReachTheRecipient() public {
        uint256 id = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        address holder = _deposit(id);
        _donateFees(id, 0.01 ether, 5e6);
        IPositionValuer.Valuation memory before = valuer.value(id);
        assertGt(before.fees0, 0, "the donation must reach the position");
        assertGt(before.fees1, 0, "the donation must reach the position");

        vm.prank(holder);
        market.collectFees(id, recipient);

        assertEq(IERC20(RobinhoodChain.WETH).balanceOf(recipient), before.fees0, "the WETH fees reach the recipient");
        assertEq(usdg.balanceOf(recipient), before.fees1, "the USDG fees reach the recipient");
        _assertOnlyTheFeesLeft(id, before);
    }

    /// @notice Whatever the fee balance, a zero decrease never pulls principal.
    function testFuzz_theClaimNeverTakesPrincipal(
        uint256 ethFee,
        uint256 usdgFee
    ) public {
        _deposit(tokenId);
        _donateFees(tokenId, bound(ethFee, 0, 1 ether), bound(usdgFee, 0, 2000e6));
        IPositionValuer.Valuation memory before = valuer.value(tokenId);

        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(recipient.balance, before.fees0, "exactly the ETH fees leave");
        assertEq(usdg.balanceOf(recipient), before.fees1, "exactly the USDG fees leave");
        _assertOnlyTheFeesLeft(tokenId, before);
    }

    /// @notice §4.1 v0.43: PositionManager is refused as a recipient. Fees paid to it would sit in its
    ///         balance, where anyone takes them with `SWEEP`.
    function test_positionManagerIsRefusedAsTheRecipient() public {
        _deposit(tokenId);
        uint256 fees1 = valuer.value(tokenId).fees1;
        address pm = address(positionManager);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, pm));
        market.collectFees(tokenId, pm);

        assertEq(valuer.value(tokenId).fees1, fees1, "the fees stay in the position");
    }

    /// @notice A second claim finds no fees and pays nothing, and still succeeds.
    /// @dev Both `TAKE`s then carry zero credit, which PositionManager skips. FAR-8 runs the same path
    ///      on a decrease whose fees were just claimed.
    function test_aSecondClaimPaysNothingAndStillSucceeds() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        vm.prank(borrower);
        market.collectFees(tokenId, recipient);
        uint256 eth = recipient.balance;
        uint256 dollars = usdg.balanceOf(recipient);

        vm.expectEmit(true, true, false, true, address(market));
        emit FarmentaMarket.CollectFees(tokenId, _keyOf(tokenId).toId(), 0, 0);
        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(recipient.balance, eth, "no more ETH");
        assertEq(usdg.balanceOf(recipient), dollars, "no more USDG");
        _assertOnlyTheFeesLeft(tokenId, before);
    }

    /// @notice Only the depositor may claim, and a refused claim leaves the fees in the position.
    function test_onlyTheDepositorMayClaim() public {
        _deposit(tokenId);
        uint256 fees0 = valuer.value(tokenId).fees0;
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotTheDepositor.selector, tokenId, borrower));
        market.collectFees(tokenId, stranger);

        assertEq(valuer.value(tokenId).fees0, fees0, "the fees stay in the position");
    }

    /// @notice §6.5: freezing a pool stops new risk, not a borrower's claim on its own fees.
    /// @dev With debt outstanding, so the health check and its price gates run on a frozen pool too.
    function test_freezingThePoolDoesNotStopTheClaim() public {
        _openLoan(20e6);
        // Read before the prank: `_keyOf` is an external call and would spend it.
        PoolId poolId = _keyOf(tokenId).toId();
        vm.prank(owner);
        policy.setFrozen(poolId, true);
        uint256 fees1 = valuer.value(tokenId).fees1;

        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(usdg.balanceOf(recipient), fees1, "a frozen pool's fees are still claimable");
    }

    /* -------------------------------- health factor --------------------------- */

    /// @notice A position well above water keeps its claim, and is still healthy after it.
    /// @dev Borrowed to the limit, so the claim runs as close to the gate as a successful claim on
    ///      the fixture's natural fees gets. The refusal itself is proved by
    ///      `test_aClaimThatWouldLeaveThePositionUnderwaterIsRefused`; this is the success path.
    function test_anIndebtedPositionWellAboveWaterClaims() public {
        _deposit(tokenId);
        _lend(300e6);
        uint256 limit = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, limit, borrower);
        uint256 debt = market.debtOf(tokenId);
        uint256 fees1 = valuer.value(tokenId).fees1;

        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(usdg.balanceOf(recipient), fees1, "the fees reach the recipient");
        assertEq(market.debtOf(tokenId), debt, "the claim does not touch the debt");
        assertGe(lens.healthFactor(tokenId), 1e18, "and the position is still healthy");
    }

    /// @notice A claim that would leave the position under water is refused, with the health factor
    ///         the lens reports for the state the claim would have left.
    /// @dev Fees above 10% of principal count as exactly 10% (§6.2), so taking them all divides the
    ///      collateral value by 1.1. Interest carries the position to a health factor just under 1.1
    ///      first: healthy before the claim, under 1 after it.
    ///
    ///      The expected figure is read from `MarketLens`, not recomputed here. The post-claim state
    ///      is reached by clearing the loan's debt shares for one claim, which then runs no health
    ///      check at all, and putting them back before asking the lens. That is the AC's "library HF
    ///      equals `MarketLens.healthFactor`" as a revert payload compared to the unit.
    function test_aClaimThatWouldLeaveThePositionUnderwaterIsRefused() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        _donateFees(tokenId, 0, v.principalUsd / 1e12 / 5);
        _lend(300e6);
        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        _ageUntilHealthFactorBelow(1.09e18);

        uint256 healthBefore = lens.healthFactor(tokenId);
        uint256 healthAfter = _healthFactorAfterClaim();
        assertGe(healthBefore, 1e18, "the position must be healthy before the claim");
        assertLt(healthAfter, 1e18, "and under water after it");
        uint256 fees1 = valuer.value(tokenId).fees1;

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.PositionWouldBeUnhealthy.selector, tokenId, healthAfter));
        market.collectFees(tokenId, recipient);

        assertEq(valuer.value(tokenId).fees1, fees1, "the fees stay in the position");
        assertEq(usdg.balanceOf(recipient), 0, "and nothing reached the recipient");
    }

    /// @notice §6.2 by hand: fees above the cap count as a tenth of principal, the removal haircut
    ///         comes off the total, and the lens health factor follows from that and nothing else.
    /// @dev The expected figures are written out here rather than read from `DebtMath`: the market,
    ///      the lens and the liquidation path all call `DebtMath.collateralValue`, so comparing them with
    ///      each other cannot catch a change to it (review of PR #18).
    function test_theLensAppliesTheFeeCapAndTheHaircutByHand() public {
        _listPoolOf(tokenId, 50e18, 500);
        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();
        _donateFees(tokenId, 0, valuer.value(tokenId).principalUsd / 1e12 / 5);
        _lend(300e6);
        uint256 amount = lens.maxBorrow(tokenId) / 2;
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);

        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertGt(v.feesUsd, v.principalUsd / 10, "the fees must sit above the cap");
        uint256 collateral = (v.principalUsd + v.principalUsd / 10) * 9500 / 10_000;
        uint256 debtUsd = market.debtOf(tokenId) * 1e18 / 1e6;

        assertEq(lens.positionValue(tokenId), collateral, "principal plus a tenth, less 5%");
        assertEq(lens.healthFactor(tokenId), collateral * 7500 * 1e18 / (debtUsd * 10_000), "at LT 75%");
    }

    /// @notice §7: the claim accrues before it checks the health factor, so interest nobody has
    ///         accrued yet still counts against it.
    /// @dev The position is brought to where the claim would leave it just above 1 at the stored
    ///      index. Sixty days then pass with nothing accrued: the stored index still says healthy, the
    ///      accrued one does not.
    function test_theClaimAccruesBeforeItChecksTheHealthFactor() public {
        _deposit(tokenId);
        _donateFees(tokenId, 0, valuer.value(tokenId).principalUsd / 1e12 / 5);
        _lend(300e6);
        uint256 limit = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, limit, borrower);

        uint256 healthAfter = _healthFactorAfterClaim();
        for (uint256 i = 0; i < 4000 && healthAfter >= 1.01e18; ++i) {
            vm.warp(block.timestamp + 1 days);
            market.accrue();
            healthAfter = _healthFactorAfterClaim();
        }
        assertGe(healthAfter, 1e18, "at the stored index the claim must pass");
        assertLt(healthAfter, 1.01e18, "and only just");

        vm.warp(block.timestamp + 60 days);
        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.PositionWouldBeUnhealthy.selector);
        market.collectFees(tokenId, recipient);
    }

    /* --------------------------------- price gates ---------------------------- */

    /// @notice §5.2 v0.40: with debt outstanding, a USDG price outside [0,97; 1,03] refuses the claim.
    function test_anIndebtedClaimRunsTheUsdgBand() public {
        _openLoan(20e6);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UsdgPriceOutOfBounds.selector, 0.96e18));
        market.collectFees(tokenId, recipient);
    }

    /// @notice §5.2 v0.40: with debt outstanding, a fresh Pyth quote over 3% from Chainlink refuses it.
    function test_anIndebtedClaimRunsThePythGate() public {
        _openLoan(20e6);
        oracle.setPythPrice(ETH_AT_POOL_SPOT * 104 / 100, block.timestamp);

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.PythPriceDeviation.selector);
        market.collectFees(tokenId, recipient);
    }

    /// @notice §5.2 v0.40: with debt outstanding, a pool more than 2% from the oracle refuses it.
    /// @dev A 3% move keeps the health factor far above 1, so the refusal can only be the gate.
    function test_anIndebtedClaimRunsTheSpotGate() public {
        _openLoan(20e6);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 97 / 100, 18);
        assertGt(valuer.value(tokenId).spotDeviationBps, 200, "the pool must be outside the 2% gate");

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.SpotPriceDeviation.selector);
        market.collectFees(tokenId, recipient);
    }

    /// @notice §6.5 and v0.40 together: a frozen pool still claims, and still runs the gates while
    ///         the position owes anything.
    function test_aFrozenPoolStillRunsTheGatesOnAnIndebtedClaim() public {
        _openLoan(20e6);
        PoolId poolId = _keyOf(tokenId).toId();
        vm.prank(owner);
        policy.setFrozen(poolId, true);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 97 / 100, 18);

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.SpotPriceDeviation.selector);
        market.collectFees(tokenId, recipient);
    }

    /// @notice With nothing owed there is no debt to protect, so none of the gates apply (v0.40).
    function test_aClaimWithNoDebtRunsNoPriceGate() public {
        _deposit(tokenId);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 80 / 100, 18);
        oracle.setPythPrice(ETH_AT_POOL_SPOT, block.timestamp);
        uint256 fees1 = valuer.value(tokenId).fees1;

        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(usdg.balanceOf(recipient), fees1, "the fees reach the recipient");
    }

    /* --------------------------------- meme market ---------------------------- */

    /// @notice §5.3: every market transaction touching a meme pool records an observation first, and a
    ///         claim is one of them.
    function test_aMemeClaimRecordsAnObservationFirst() public {
        FarmentaMarket memeMarket = _openMemeMarket();
        PoolId poolId = _keyOf(tokenId).toId();
        uint256 records = oracle.recordCount(poolId);

        vm.prank(borrower);
        memeMarket.collectFees(tokenId, recipient);

        assertEq(oracle.recordCount(poolId), records + 1, "the claim recorded the pool once");
    }

    /// @notice A blue-chip claim has no TWAP to feed, and pays nothing for one.
    function test_aBlueChipClaimRecordsNothing() public {
        _deposit(tokenId);
        PoolId poolId = _keyOf(tokenId).toId();

        vm.prank(borrower);
        market.collectFees(tokenId, recipient);

        assertEq(oracle.recordCount(poolId), 0, "no observation for a blue-chip pool");
    }

    /// @notice §5.2 v0.40 on a meme market: Pyth and the ±2% spot gate are blue-chip rules, so neither
    ///         holds up an indebted claim there.
    /// @dev Both conditions are live at once, and each alone refuses a blue-chip claim. A health check
    ///      run at the wrong tier fails here with `PythPriceDeviation` (review of PR #18, mutant A5).
    function test_anIndebtedMemeClaimIsNotHeldByPythOrSpot() public {
        FarmentaMarket memeMarket = _openMemeMarket();
        vm.prank(borrower);
        memeMarket.borrow(tokenId, 10e6, borrower);

        oracle.setPythPrice(ETH_AT_POOL_SPOT * 104 / 100, block.timestamp);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 95 / 100, 18);
        assertGt(valuer.value(tokenId).spotDeviationBps, 200, "the pool must be outside the blue-chip spot gate");
        uint256 fees1 = valuer.value(tokenId).fees1;

        vm.prank(borrower);
        memeMarket.collectFees(tokenId, recipient);

        assertEq(usdg.balanceOf(recipient), fees1, "the fees reach the recipient");
    }

    /// @notice §5.2 v0.40 on a meme market: the USDG band applies to every tier.
    function test_anIndebtedMemeClaimStillRunsTheUsdgBand() public {
        FarmentaMarket memeMarket = _openMemeMarket();
        vm.prank(borrower);
        memeMarket.borrow(tokenId, 10e6, borrower);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UsdgPriceOutOfBounds.selector, 0.96e18));
        memeMarket.collectFees(tokenId, recipient);
    }

    /* ------------------------------ outbound calls ---------------------------- */

    /// @notice §4.1 v0.26: the borrow asset leaves before any other leg, so a native-ETH recipient
    ///         already holds its USDG fees when its code first runs.
    /// @dev `TAKE_PAIR` pays `currency0` first, and in this pool that is the ETH: under it the
    ///      recipient would see no USDG at all.
    function test_theUsdgLegLeavesBeforeTheEth() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory v = valuer.value(tokenId);
        assertGt(v.fees0, 0, "the fixture must hold ETH fees");
        assertGt(v.fees1, 0, "the fixture must hold USDG fees");
        RedeemingRecipient receiver = new RedeemingRecipient(market);

        vm.prank(borrower);
        market.collectFees(tokenId, address(receiver));

        assertEq(receiver.usdgOnEthArrival(), v.fees1, "the USDG fees were already there when the ETH arrived");
        assertEq(address(receiver).balance, v.fees0, "and the ETH fees arrived in full");
    }

    /// @notice §4.1 v0.26: a vault redeem made from inside the claim's ETH payout is priced exactly
    ///         as one made after the claim.
    /// @dev Thirty days of interest are left unaccrued, so the redeem inside the payout is the first
    ///      thing to see them unless the claim's own accrual already has. Either way the claim moves
    ///      no cash, debt or reserve, so there is no half-written ledger for the redeem to read; this
    ///      pins that property down for the day `collectFees` starts writing anything more.
    function test_aRedeemFromInsideTheClaimGainsNothing() public {
        _openLoan(100e6);
        RedeemingRecipient attacker = new RedeemingRecipient(market);
        deal(address(usdg), address(attacker), 100e6);
        attacker.deposit(100e6);
        vm.warp(block.timestamp + 30 days);

        uint256 shares = market.balanceOf(address(attacker));
        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        market.collectFees(tokenId, recipient);
        uint256 fair = market.previewRedeem(shares);
        vm.revertToState(snapshot);

        attacker.arm();
        vm.prank(borrower);
        market.collectFees(tokenId, address(attacker));

        assertGt(attacker.redeemed(), 0, "the redeem must actually run inside the payout");
        assertEq(attacker.redeemed(), fair, "a share redeemed mid-claim is worth what it is worth after");
    }

    /* --------------------------------- helpers -------------------------------- */

    function _deposit(
        uint256 id
    ) private returns (address holder) {
        _listPoolOf(id, 50e18);
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

    /// @dev The AC's invariant: a claim changes the fee balance and nothing else about the position.
    function _assertOnlyTheFeesLeft(
        uint256 id,
        IPositionValuer.Valuation memory before
    ) private view {
        IPositionValuer.Valuation memory afterClaim = valuer.value(id);
        assertEq(afterClaim.liquidity, before.liquidity, "the position's liquidity is identical");
        assertEq(positionManager.getPositionLiquidity(id), before.liquidity, "and so is PositionManager's");
        assertEq(afterClaim.amount0, before.amount0, "principal0 is untouched");
        assertEq(afterClaim.amount1, before.amount1, "principal1 is untouched");
        assertEq(afterClaim.fees0, 0, "no currency0 fee is left behind");
        assertEq(afterClaim.fees1, 0, "no currency1 fee is left behind");
    }

    /// @dev The health factor the lens reports once the claim has gone through, with the debt it
    ///      has now. See `test_aClaimThatWouldLeaveThePositionUnderwaterIsRefused`.
    function _healthFactorAfterClaim() private returns (uint256 healthFactor) {
        bytes32 slot = _debtSharesSlot(tokenId);
        bytes32 shares = vm.load(address(market), slot);
        uint256 snapshot = vm.snapshotState();

        vm.store(address(market), slot, bytes32(0));
        vm.prank(borrower);
        market.collectFees(tokenId, recipient);
        vm.store(address(market), slot, shares);
        healthFactor = lens.healthFactor(tokenId);

        vm.revertToState(snapshot);
    }

    /// @dev `Layout.loans` is the second field, so its slot is `LOCATION + 1`; within a `Loan`,
    ///      `owner` and `tier` share the first slot and `debtShares` takes the next.
    function _debtSharesSlot(
        uint256 id
    ) private pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(id, uint256(MarketLedger.LOCATION) + 1))) + 1);
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
}
