// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {MarketLedger} from "../../src/libraries/MarketLedger.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

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
    function test_anIndebtedPositionWellAboveWaterClaims() public {
        _openLoan(20e6);
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
    /// @dev A 1% move keeps the health factor far above 1, so the refusal can only be the gate.
    function test_anIndebtedClaimRunsTheSpotGate() public {
        _openLoan(20e6);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT * 97 / 100, 18);
        assertGt(valuer.value(tokenId).spotDeviationBps, 200, "the pool must be outside the 2% gate");

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
