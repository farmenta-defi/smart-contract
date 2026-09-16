// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {DebtMath} from "./DebtMath.sol";

/// @title LiquidationMath
/// @notice Everything §8 decides about a seizure before any state moves.
/// @dev Kept out of `FarmentaMarket` for two reasons. The first is bytecode: the market
///      implementation sits close to EIP-170 and every arithmetic branch it does not carry is
///      room the remaining §4.1 functions still need (see the `deploy` profile note in
///      foundry.toml). The second is that these are the numbers an auditor checks one at a
///      time — close factor, the repay cap, the bonus, the fee credit, the liquidity slice —
///      and they are easier to check as pure functions over explicit inputs than as lines
///      inside a function that is also moving tokens.
///
///      **Every rounding direction here points the same way, and it is deliberate.** §6.2
///      rounds the protocol's liquidation fee down "so the rounding difference always falls to
///      the liquidator", and the same reasoning applies to the rest: the liquidator is the
///      party the protocol needs to show up, and a wei of slack is cheaper than a seizure that
///      does not happen. One exception is `retainedFee`, which rounds **up** — what it
///      measures is the borrower's share, kept back from the liquidator, and rounding that up
///      is what keeps the §8 step 5 invariant (payout ≤ `repay × (1 + bonus)`) true rather
///      than true-to-within-a-wei. `purchase` is the other: it rounds the price of a fee leg
///      up, so a purchase made without a bonus cannot become one through rounding.
library LiquidationMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Blue-chip closes half a position at a time (§6.2).
    uint16 internal constant BLUE_CHIP_CLOSE_FACTOR_BPS = 5000;

    /// @notice Below this health factor the whole debt may be closed at once (§6.2).
    /// @dev The partial close factor exists to leave a borrower something to recover with. A
    ///      position this far under water has nothing to recover: waiting out a second
    ///      liquidation only lets the shortfall grow into bad debt.
    uint256 internal constant FULL_CLOSE_HF = 0.9e18;

    /// @notice Debts under this size may be closed in one go (§6.2).
    /// @dev **100 USDG, not $100** — the unit is the ledger's, 6 decimals, the same as the
    ///      10 USDG borrow minimum. Reading it as USD is the exact mistake that rejected a
    ///      10 USDG borrow while USDG traded at 0,98 (PR #7), and it is worse here: it would
    ///      move the boundary at which a liquidator may close a whole position.
    uint256 internal constant FULL_CLOSE_DEBT_USDG = 100e6;

    /// @notice The health factor used by the liquidation gate and its read-only lens.
    /// @dev Keeping this calculation here prevents a keeper-facing view from drifting from the
    ///      gate when liquidation prices differ from borrow prices (for example, meme TWAP).
    function healthFactor(
        uint256 principalUsd,
        uint256 feesUsd,
        uint16 removeHaircutBps,
        uint16 ltBps,
        uint256 debt,
        uint256 debtPrice,
        uint8 debtDecimals
    ) internal pure returns (uint256) {
        return DebtMath.healthFactor(
            DebtMath.collateralValue(principalUsd, feesUsd, removeHaircutBps),
            ltBps,
            DebtMath.debtUsd(debt, debtPrice, debtDecimals)
        );
    }

    /// @param debt What the position owes, USDG 6 decimals.
    /// @param repayRequested What the liquidator asked to repay, USDG 6 decimals.
    /// @param realizableUsd `value` of §8 step 1: principal + **all** fees, after the §6.3
    ///        haircut, USD 1e18. Not the capped `collateralValue` the health factor uses —
    ///        seizing against a capped value would hand out more than `repay × (1 + bonus)`.
    /// @param feeUsd The uncollected-fee part of `realizableUsd`, after the same haircut.
    /// @param usdgPrice USD price of one whole USDG, 1e18 (§7: the debt side is priced, not
    ///        assumed to be par).
    /// @param usdgDecimals Decimals of the borrow asset, from the listing.
    /// @param closeFactorBps_ The close factor already resolved for this position.
    /// @param bonusBps The pool's gross liquidator bonus (§6.2).
    /// @param liquidity Position liquidity backing the principal.
    struct Inputs {
        uint256 debt;
        uint256 repayRequested;
        uint256 realizableUsd;
        uint256 feeUsd;
        uint256 usdgPrice;
        uint8 usdgDecimals;
        uint16 closeFactorBps_;
        uint16 bonusBps;
        uint128 liquidity;
    }

    /// @param repay USDG the liquidator pays against the debt.
    /// @param protocolFee USDG the liquidator pays on top, credited to `reserves` (§6.2).
    /// @param seizeValue `repay × (1 + bonus)`, USD 1e18 — the ceiling on what the liquidator
    ///        may walk away with.
    /// @param feeCredit The part of `seizeValue` paid out of uncollected fees (§8 step 5).
    ///        Zero on the full-seizure branch, which takes the position whole.
    /// @param liqToRemove Liquidity to pull for the principal part of the seizure.
    /// @param fullSeizure True when the seizure takes the entire position (§8 step 4).
    struct Plan {
        uint256 repay;
        uint256 protocolFee;
        uint256 seizeValue;
        uint256 feeCredit;
        uint128 liqToRemove;
        bool fullSeizure;
    }

    /// @notice How much of a debt one liquidation may close (§6.2).
    /// @dev The meme tier closes in full always: its positions are the ones whose value moves
    ///      fastest, and a half-closed meme position is a second liquidation that has to
    ///      arrive before the next move.
    function closeFactorBps(
        ICollateralPolicy.Tier tier,
        uint256 healthFactor_,
        uint256 debt
    ) internal pure returns (uint16) {
        if (tier == ICollateralPolicy.Tier.MEME) return uint16(BPS);
        if (healthFactor_ < FULL_CLOSE_HF || debt < FULL_CLOSE_DEBT_USDG) return uint16(BPS);
        return BLUE_CHIP_CLOSE_FACTOR_BPS;
    }

    /// @notice Turns a liquidation request into the seizure §8 allows for it.
    /// @dev Steps 2 and 5 of §8, in one place, because they are one decision: how much the
    ///      liquidator may repay decides what they may seize, and what there is to seize
    ///      decides whether the position survives the call.
    ///
    ///      **The repay cap is what picks the branch.** A `repay` whose bonus-inflated seizure
    ///      reaches past everything the position holds is cut down to `value ÷ (1 + bonus)`
    ///      (§8 step 2, v0.12), and that cut is the definition of the full-seizure branch: the
    ///      liquidator never pays for more than they can be handed, and the bad debt that
    ///      follows does not depend on the `repayAmount` they happened to type.
    function plan(
        Inputs memory i
    ) internal pure returns (Plan memory p) {
        p.repay = Math.min(i.repayRequested, i.debt * i.closeFactorBps_ / BPS);
        p.seizeValue = _seizeValue(p.repay, i);

        if (p.seizeValue >= i.realizableUsd) {
            p.fullSeizure = true;
            // `value ÷ (1 + bonus)`, floored twice on the way back into USDG. Both floors cost
            // the liquidator, never the position, so the capped repay can only under-reach
            // `realizableUsd` — never seize past it.
            p.repay = DebtMath.usdToDebt(i.realizableUsd * BPS / (BPS + i.bonusBps), i.usdgPrice, i.usdgDecimals);
            p.seizeValue = _seizeValue(p.repay, i);
        } else {
            p.feeCredit = Math.min(i.feeUsd, p.seizeValue);
            // The principal the slice is measured against. `realizableUsd` and `feeUsd` carry
            // the same haircut, so the subtraction leaves principal after haircut — the value
            // the liquidity actually stands for.
            uint256 principalUsd = i.realizableUsd - i.feeUsd;
            p.liqToRemove = principalUsd == 0
                ? 0
                : uint128(Math.min(Math.mulDiv(i.liquidity, p.seizeValue - p.feeCredit, principalUsd), i.liquidity));
        }

        // §6.2 v0.8: derived at liquidation time from the same terms that granted the bonus,
        // so a listing that tightens the bonus cannot leave the two disagreeing.
        p.protocolFee = p.repay * (i.bonusBps / 10) / BPS;
    }

    /// @notice The fee amount held back from the liquidator, in one currency.
    /// @param received What the market took out of the position for that currency.
    /// @param feeAmount The position's uncollected fees in that currency, after the §6.3
    ///        haircut — the hook skims what leaves, so what arrived is already net of it.
    /// @param feeUsd Value of all uncollected fees, after haircut.
    /// @param feeCredit The part of that fee value the seizure is entitled to.
    /// @dev Only ever non-zero when the fees outrun the seizure allowance, which is the shape
    ///      the v0.2 gap lived in: a liquidator naming a tiny `repayAmount` against a fee-rich
    ///      position collected every fee in it, because a decrease realises the whole fee
    ///      balance no matter how little liquidity it pulls.
    ///
    ///      Rounded up and capped at what arrived: up because the remainder is the borrower's,
    ///      capped because a hook that skims more than its recorded haircut would otherwise
    ///      make this exceed the balance the market is holding.
    function retainedFee(
        uint256 received,
        uint256 feeAmount,
        uint256 feeUsd,
        uint256 feeCredit
    ) internal pure returns (uint256) {
        if (feeUsd <= feeCredit || feeAmount == 0) return 0;
        return Math.min(Math.mulDiv(feeAmount, feeUsd - feeCredit, feeUsd, Math.Rounding.Ceil), received);
    }

    /// @notice How much of the borrower's non-USDG fee leg a liquidator buys, and for what
    ///         (§8 step 5, v0.26).
    /// @param amount Units of the leg left over after the seizure took its fee credit.
    /// @param priceUsd USD price of one whole unit of that currency, liquidation prices, 1e18.
    /// @param decimals Decimals of that currency, from the listing.
    /// @param usdgPrice USD price of one whole USDG, liquidation prices, 1e18.
    /// @param usdgDecimals Decimals of the borrow asset.
    /// @param remainingDebt Debt left once `repay` and the borrower's own USDG fees are applied.
    /// @return bought Units of the leg the liquidator takes.
    /// @return cost USDG the liquidator pays for them, all of it against the debt.
    /// @dev At value, with no bonus and no protocol fee: this is a sale, not a seizure, so it
    ///      counts toward neither the close factor nor the `repay x (1 + bonus)` ceiling.
    ///
    ///      Capped at the debt, because fees can only repay a debt that exists; what the debt
    ///      cannot absorb stays the borrower's. Both rounding directions go against the
    ///      liquidator — the price up, the capped amount down — so no purchase is ever a
    ///      discount.
    function purchase(
        uint256 amount,
        uint256 priceUsd,
        uint8 decimals,
        uint256 usdgPrice,
        uint8 usdgDecimals,
        uint256 remainingDebt
    ) internal pure returns (uint256 bought, uint256 cost) {
        if (amount == 0 || remainingDebt == 0) return (0, 0);

        uint256 fullCost =
            Math.mulDiv(amount * priceUsd, 10 ** usdgDecimals, (10 ** decimals) * usdgPrice, Math.Rounding.Ceil);
        if (fullCost <= remainingDebt) return (amount, fullCost);
        return (Math.mulDiv(amount, remainingDebt, fullCost), remainingDebt);
    }

    function _seizeValue(
        uint256 repay,
        Inputs memory i
    ) private pure returns (uint256) {
        return DebtMath.debtUsd(repay, i.usdgPrice, i.usdgDecimals) * (BPS + i.bonusBps) / BPS;
    }
}
