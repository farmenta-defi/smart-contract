// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";

/// @notice The §8 seizure arithmetic, checked one number at a time. No network, no tokens.
contract LiquidationMathTest is Test {
    uint256 internal constant ONE_USD = 1e18;

    /* ------------------------------- close factor ----------------------------- */

    function test_blueChipClosesHalfWhileTheShortfallIsSmall() public pure {
        assertEq(_closeFactor(ICollateralPolicy.Tier.BLUE_CHIP, 0.95e18, 500e6), 5000);
    }

    /// @dev Both escape hatches of §6.2, each on its own.
    function test_blueChipClosesInFullWellUnderWaterOrOnADustDebt() public pure {
        assertEq(_closeFactor(ICollateralPolicy.Tier.BLUE_CHIP, 0.8999e18, 500e6), 10_000);
        assertEq(_closeFactor(ICollateralPolicy.Tier.BLUE_CHIP, 0.95e18, 99.999999e6), 10_000);
    }

    /// @dev The boundary itself stays on the partial side: §6.2 says *below* 0,9.
    function test_theFullCloseBoundariesAreExclusive() public pure {
        assertEq(_closeFactor(ICollateralPolicy.Tier.BLUE_CHIP, 0.9e18, 100e6), 5000);
    }

    /// @dev 100 USDG, read in the ledger's 6 decimals. Were it read as USD 1e18, every debt on
    ///      the book would sit under the threshold and blue-chip would always close in full.
    function test_theSmallDebtThresholdIsOneHundredUsdgNotUsd() public pure {
        assertEq(LiquidationMath.FULL_CLOSE_DEBT_USDG, 100e6);
        assertEq(_closeFactor(ICollateralPolicy.Tier.BLUE_CHIP, 0.95e18, 100e6), 5000);
    }

    function test_memeAlwaysClosesInFull() public pure {
        assertEq(_closeFactor(ICollateralPolicy.Tier.MEME, 0.99e18, 10_000e6), 10_000);
    }

    /* ---------------------------------- plan ---------------------------------- */

    /// @notice The ordinary partial seizure: bonus on top of the repay, protocol fee a tenth
    ///         of the bonus, liquidity pulled for the principal part.
    /// @dev A $1,000 position with no fees, 500 USDG repaid at a 5% bonus: the liquidator is
    ///         owed $525 of a $1,000 position, so 52.5% of its liquidity comes out.
    function test_partialSeizureTakesTheBonusInflatedSliceOfLiquidity() public pure {
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(1000e18, 0, 500e6, 1000e6, 500, 1e18));

        assertFalse(p.fullSeizure, "a $525 seizure fits inside a $1,000 position");
        assertEq(p.repay, 500e6, "the request is under the close factor");
        assertEq(p.seizeValue, 525e18, "repay x (1 + 5%)");
        assertEq(p.feeCredit, 0, "a position with no fees has no fee credit");
        assertEq(p.liqToRemove, 0.525e18, "52.5% of the liquidity backs $525 of a $1,000 position");
        assertEq(p.protocolFee, 2.5e6, "0,5% of repay, a tenth of the 5% bonus");
    }

    /// @dev §6.2 v0.8: the protocol fee is derived from the pool's own bonus, so a listing
    ///      that tightens the bonus raises the fee with it and the two cannot drift apart.
    function test_theProtocolFeeIsAlwaysATenthOfTheBonus() public pure {
        LiquidationMath.Plan memory meme = LiquidationMath.plan(_inputs(10_000e18, 0, 1000e6, 5000e6, 1000, 1e18));
        assertEq(meme.protocolFee, 10e6, "1% of repay, a tenth of the 10% meme bonus");

        LiquidationMath.Plan memory tightened = LiquidationMath.plan(_inputs(10_000e18, 0, 1000e6, 5000e6, 1500, 1e18));
        assertEq(tightened.protocolFee, 15e6, "a 15% bonus pays 1,5%, with no owner action");
    }

    /// @dev Rounding down is §6.2's own instruction, and the direction matters: the difference
    ///      lands with the liquidator, the party the protocol needs to turn up.
    function test_theProtocolFeeRoundsDownToTheLiquidatorsBenefit() public pure {
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(1000e18, 0, 199, 1000e6, 500, 1e18));
        assertEq(p.protocolFee, 0, "0,5% of 199 is 0,995 - floored, so nothing");
    }

    /// @notice Step 2's cap: a repay whose seizure would reach past the position is cut to
    ///         what the position can actually pay, and that cut is the full-seizure branch.
    function test_aSeizureThatOutgrowsThePositionIsCappedAndTakesItWhole() public pure {
        // A $1,000 position against a 2,000 USDG debt, closing in full.
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(1000e18, 0, 2000e6, 2000e6, 500, 1e18));

        assertTrue(p.fullSeizure, "the position cannot cover a 2,000 USDG repay plus bonus");
        assertEq(p.repay, 952.380952e6, "value divided by 1,05, floored");
        assertLe(p.seizeValue, 1000e18, "a capped repay can never seize past the position");
        assertEq(p.liqToRemove, 0, "the full branch burns the position rather than slicing it");
        assertEq(p.feeCredit, 0, "there is nothing to hold back when everything is taken");
    }

    /// @dev The property the cap exists for (§8 step 2, v0.12): bad debt is a fact about the
    ///      position, not about the number the liquidator typed.
    function test_theCappedRepayDoesNotDependOnWhatWasRequested() public pure {
        LiquidationMath.Plan memory modest = LiquidationMath.plan(_inputs(1000e18, 0, 1500e6, 5000e6, 500, 1e18));
        LiquidationMath.Plan memory greedy = LiquidationMath.plan(_inputs(1000e18, 0, 5000e6, 5000e6, 500, 1e18));

        assertEq(modest.repay, greedy.repay, "both requests reach past the position, so both cap alike");
        assertTrue(modest.fullSeizure && greedy.fullSeizure);
    }

    /// @notice The close factor binds before the bonus does.
    function test_theCloseFactorLimitsTheRepayBeforeAnythingElse() public pure {
        LiquidationMath.Inputs memory i = _inputs(10_000e18, 0, 1000e6, 1000e6, 500, 1e18);
        i.closeFactorBps_ = 5000;

        LiquidationMath.Plan memory p = LiquidationMath.plan(i);
        assertEq(p.repay, 500e6, "half the debt, however much was asked for");
        assertEq(p.protocolFee, 2.5e6, "the fee follows the capped repay, not the request");
    }

    /// @notice The v0.2 regression, in arithmetic: a tiny repay against a fee-rich position
    ///         buys a fee credit of its own size, not the whole fee balance.
    function test_aTinyRepayBuysOnlyItsOwnShareOfARichFeeBalance() public pure {
        // $1,000 position, $400 of it uncollected fees, 10 USDG repaid at a 5% bonus.
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(1000e18, 400e18, 10e6, 1000e6, 500, 1e18));

        assertEq(p.seizeValue, 10.5e18, "repay x 1,05");
        assertEq(p.feeCredit, 10.5e18, "fees cover the seizure whole, so the credit is the seizure");
        assertEq(p.liqToRemove, 0, "nothing is owed out of principal, so no liquidity is pulled");
    }

    /// @dev Fees are paid out first and liquidity covers only what is left over, so the slice
    ///      is measured against principal alone — `value - feeValue`, not `value`.
    function test_liquidityCoversOnlyTheSeizureLeftAfterTheFeeCredit() public pure {
        // $1,000 position, $100 of fees → $900 of principal; a $525 seizure takes $100 of fees
        // and $425 of principal, which is 425/900 of the liquidity.
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(1000e18, 100e18, 500e6, 1000e6, 500, 1e18));

        assertEq(p.feeCredit, 100e18, "the whole fee balance is inside the seizure");
        assertEq(p.liqToRemove, uint128(uint256(1e18) * 425 / 900), "the rest comes out of principal");
    }

    /// @dev A position that is nothing but fees has no principal to measure a slice against.
    ///      The division that would ask for one must not happen.
    function test_aPositionThatIsAllFeesPullsNoLiquidity() public pure {
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(100e18, 100e18, 10e6, 1000e6, 500, 1e18));

        assertEq(p.liqToRemove, 0, "no principal, no slice");
        assertEq(p.feeCredit, 10.5e18, "the seizure is paid entirely out of fees");
    }

    /// @dev §7: the debt side is priced, not assumed to be par. A cheaper USDG buys less
    ///      collateral per unit repaid, and the seizure has to shrink with it.
    function test_theSeizureFollowsTheUsdgPrice() public pure {
        LiquidationMath.Plan memory p = LiquidationMath.plan(_inputs(1000e18, 0, 500e6, 1000e6, 500, 0.98e18));
        assertEq(p.seizeValue, 514.5e18, "500 USDG at $0,98 is $490, plus the 5% bonus");
    }

    /* ------------------------------- retained fee ----------------------------- */

    function test_nothingIsHeldBackWhileTheSeizureCoversTheFees() public pure {
        assertEq(LiquidationMath.retainedFee(1000, 400, 100e18, 100e18), 0);
        assertEq(LiquidationMath.retainedFee(1000, 400, 100e18, 250e18), 0);
    }

    /// @dev Three quarters of the fee value is beyond the credit, so three quarters of each
    ///      fee currency stays with the borrower.
    function test_theBorrowersShareIsProRataAcrossTheFeeCurrencies() public pure {
        assertEq(LiquidationMath.retainedFee(1000, 400, 100e18, 25e18), 300);
        assertEq(LiquidationMath.retainedFee(1000, 40, 100e18, 25e18), 30);
    }

    /// @dev Rounding up here is what makes the §8 step 5 payout invariant exact rather than
    ///      approximate: a wei that cannot be split cleanly stays on the borrower's side.
    function test_theBorrowersShareRoundsUp() public pure {
        assertEq(LiquidationMath.retainedFee(1000, 3, 100e18, 50e18), 2, "1,5 wei of fees rounds to 2");
    }

    /// @dev A hook that skims more than its recorded haircut would leave the market holding
    ///      less than the arithmetic expects. Capping at what arrived keeps that from
    ///      underflowing the liquidator's payout.
    function test_theBorrowersShareNeverExceedsWhatArrived() public pure {
        assertEq(LiquidationMath.retainedFee(10, 400, 100e18, 0), 10);
    }

    /* --------------------------------- helpers -------------------------------- */

    function _closeFactor(
        ICollateralPolicy.Tier tier,
        uint256 healthFactor,
        uint256 debt
    ) private pure returns (uint16) {
        return LiquidationMath.closeFactorBps(tier, healthFactor, debt);
    }

    /// @dev A position worth `realizableUsd` with `feeUsd` of that in uncollected fees, held
    ///      as 1e18 of liquidity, against `debt` of USDG debt closing in full.
    function _inputs(
        uint256 realizableUsd,
        uint256 feeUsd,
        uint256 repayRequested,
        uint256 debt,
        uint16 bonusBps,
        uint256 usdgPrice
    ) private pure returns (LiquidationMath.Inputs memory) {
        return LiquidationMath.Inputs({
            debt: debt,
            repayRequested: repayRequested,
            realizableUsd: realizableUsd,
            feeUsd: feeUsd,
            usdgPrice: usdgPrice,
            usdgDecimals: 6,
            closeFactorBps_: 10_000,
            bonusBps: bonusBps,
            liquidity: 1e18
        });
    }
}
