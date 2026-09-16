// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {DebtMath} from "./DebtMath.sol";
import {LiquidationMath} from "./LiquidationMath.sol";
import {MarketLedger} from "./MarketLedger.sol";

/// @dev The one PositionManager getter this library needs that `IPositionManager` does not
///      declare. It comes from periphery's `NativeWrapper`, which PositionManager inherits.
interface INativeWrapper {
    function WETH9() external view returns (IWETH9);
}

/// @title MarketLiquidation
/// @notice Everything a §8 seizure does that is not a write to the market's ledger.
/// @dev **A deployed library, called by `delegatecall`, and that is load-bearing twice over.**
///      It runs in the market's context, so `address(this)` is the market and `msg.sender` is
///      still the liquidator: the USDG pull, the `modifyLiquidities` call that only the NFT's
///      owner may make, and every payout all behave exactly as they would inside the market.
///      And its code lives at its own address, which is the reason this file exists at all:
///      the seizure is several kilobytes, and the market implementation has to stay under
///      EIP-170 while §4.1's remaining entrypoints still arrive. Since FAR-32 that is the rule
///      for every path (§4.1 v0.33): logic in a linked library, a wrapper in the market.
///
///      It writes the market's ledger too, through `MarketLedger` — the one declaration of
///      that layout, shared rather than copied, so the two compilation units cannot drift into
///      disagreeing about where a slot is. The market keeps the parts that have to be seen from
///      outside: the guard, the accrual, and every event.
library MarketLiquidation {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    /// @notice Gas offered with the borrower's share of the fees when it is native ETH.
    /// @dev Enough for a smart-contract wallet to accept it, and a bound on what a borrower
    ///      can burn. Refusing it costs the borrower nothing but the form: the ETH arrives as
    ///      WETH instead (see `_pay`).
    uint256 private constant BORROWER_ETH_GAS = 50_000;

    /// @notice The market's dependencies, which a delegatecall cannot read for itself.
    /// @dev They are `immutable` in the market implementation (§4.1), and immutables live in
    ///      the caller's code, not its storage. Passing them in keeps that so: this library
    ///      never decides which oracle or policy applies, it is told.
    struct Env {
        IPositionManager positionManager;
        ICollateralPolicy policy;
        IPositionValuer valuer;
        IPriceOracle oracle;
        address asset;
    }

    /// @param tokenId The position to liquidate.
    /// @param repayAmount USDG the liquidator offered.
    /// @param minOut0 Least currency0 the liquidator accepts, on what they receive.
    /// @param minOut1 Least currency1 the liquidator accepts, on what they receive.
    /// @param to Where the seized tokens go.
    struct Request {
        uint256 tokenId;
        uint256 repayAmount;
        uint128 minOut0;
        uint128 minOut1;
        address to;
    }

    /// @param repaid USDG taken off the debt, including the borrower's own retained fees.
    /// @param out0 currency0 the liquidator received.
    /// @param out1 currency1 the liquidator received.
    /// @param badDebt Debt the position could not cover — only ever non-zero on the full
    ///        branch, where the position stops existing.
    /// @param socialized The part of `badDebt` the reserve could not cover, which lands on
    ///        `totalAssets` and therefore on this market's depositors (§9 layer 3).
    /// @param fullSeizure Whether the position was taken whole.
    struct Outcome {
        uint256 repaid;
        uint256 out0;
        uint256 out1;
        uint256 badDebt;
        uint256 socialized;
        bool fullSeizure;
    }

    /// @notice What one seizure worked out before it moved anything.
    /// @param feeUsd Value of the uncollected fees after the §6.3 haircut, USD 1e18.
    /// @param fee0 Uncollected currency0 fees, after the same haircut.
    /// @param fee1 Uncollected currency1 fees, after the same haircut.
    /// @param usdgPrice USD price of one whole USDG at liquidation prices, 1e18.
    /// @param usdgDecimals Decimals of the borrow asset, from the listing.
    /// @param plan The seizure §8 allows.
    struct Context {
        uint256 feeUsd;
        uint256 fee0;
        uint256 fee1;
        uint256 usdgPrice;
        uint8 usdgDecimals;
        LiquidationMath.Plan plan;
    }

    /// @notice The position is not underwater, so there is nothing to liquidate (§8 step 1).
    error PositionIsHealthy(uint256 tokenId, uint256 healthFactor);

    /// @notice A partial seizure that would repay nothing. Refused: it still realises the
    ///         borrower's whole fee balance, so it is a way to strip fees for gas.
    error NothingToRepay(uint256 tokenId);

    /// @notice The liquidator received less than they said they would accept.
    error SeizureBelowMinimum(uint256 out0, uint256 out1);

    /// @notice The seized tokens were addressed nowhere, or back at the market itself.
    error InvalidRecipient(address to);

    /// @notice The market is not holding this position as anyone's collateral.
    error PositionNotCollateral(uint256 tokenId);

    /// @notice The fees the seizure was not entitled to include a non-USDG leg the liquidator
    ///         has to buy while debt remains (§8 step 5, v0.26), and what `repayAmount` leaves
    ///         after `repay` does not pay for it.
    /// @param required USDG the purchase costs.
    /// @param available USDG `repayAmount` left for it.
    error FeePurchaseUnderfunded(uint256 required, uint256 available);

    /// @notice Runs §8 in full: value, gate, charge, seize, settle the ledger, and pay out.
    /// @dev The caller has already accrued interest and taken the reentrancy guard, and emits
    ///      the events from what this returns. Everything between is here.
    ///
    ///      **The ledger is written before anything leaves the market, and USDG leaves before
    ///      anything else.** The market's guard covers the market's own functions but not the
    ///      ERC-4626 exits: `withdraw` and `redeem` stay open, because nothing a lender does
    ///      needs them closed. Meanwhile a native-ETH payout runs the recipient's code. If the
    ///      ledger were still unwritten at that moment, `totalAssets` would count the
    ///      liquidator's USDG as cash while the debt it repays — and, on the full branch, the
    ///      bad debt about to be socialized — still sat in `totalBorrows`. A lender redeeming
    ///      from inside the payout would be paid at that inflated price and leave the
    ///      difference to every other depositor. So:
    ///
    ///      - partial branch: the slice comes into the market, which runs no code on receipt.
    ///        Then the USDG is pulled (repay, protocol fee, and any fee leg §8 step 5 makes the
    ///        liquidator buy) and the ledger written, and only then is anything paid
    ///        out, the borrow asset first, so no callback sees cash the ledger has not settled;
    ///      - full branch: the USDG is pulled and the ledger written before the burn, whose
    ///        `TAKE_PAIR` is the first thing that can call out.
    ///
    ///      Pool hooks run inside `modifyLiquidities` as well. On the partial branch they see the
    ///      market untouched, on the full branch settled, and never a state in between.
    function execute(
        Env memory env,
        Request memory r
    ) public returns (Outcome memory o) {
        if (r.to == address(0) || r.to == address(this)) revert InvalidRecipient(r.to);

        MarketLedger.Loan memory loan = MarketLedger.layout().loans[r.tokenId];
        if (loan.owner == address(0)) revert PositionNotCollateral(r.tokenId);

        uint256 debt = DebtMath.debtOf(loan.debtShares, MarketLedger.layout().borrowIndex);
        Context memory c = _plan(env, r, loan, debt);
        if (c.plan.repay == 0 && !c.plan.fullSeizure) revert NothingToRepay(r.tokenId);

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(r.tokenId);
        o.fullSeizure = c.plan.fullSeizure;

        Split memory s;
        if (o.fullSeizure) {
            o.repaid = c.plan.repay;
            o.badDebt = debt - o.repaid;
        } else {
            s = _takeSlice(env, r, c, key);
            _settleRetainedFees(env, r, c, key, s, debt - c.plan.repay);
            o.repaid = c.plan.repay + s.applied + s.cost;
        }

        // Step 3, plus the fee leg step 5 makes the liquidator buy. `msg.sender` survives the
        // delegatecall, so this is the liquidator paying.
        IERC20(env.asset).safeTransferFrom(msg.sender, address(this), c.plan.repay + c.plan.protocolFee + s.cost);

        // Step 6.
        _retireLoan(r.tokenId, loan, o.repaid, debt, o.fullSeizure);
        o.socialized = _settleReserves(c.plan.protocolFee, o.badDebt);

        if (o.fullSeizure) {
            (o.out0, o.out1) = _seizeWholePosition(env, r, key);
        } else {
            _payOut(env, r, key, loan.owner, s);
            (o.out0, o.out1) = (s.out0, s.out1);
        }

        // Measured on what the liquidator received, not on what reached the market: on the
        // partial branch those differ by exactly the borrower's share of the fees.
        if (o.out0 < r.minOut0 || o.out1 < r.minOut1) revert SeizureBelowMinimum(o.out0, o.out1);
    }

    /// @dev Retires debt shares, and clears the record when the position itself is gone.
    ///
    ///      One path for both branches because they differ in one place only: the partial
    ///      branch retires the shares the repayment bought, the full branch retires every share
    ///      the loan held — including the part no repayment covered, which `_settleReserves`
    ///      then accounts for. A debt settled to zero retires the exact recorded shares rather
    ///      than a computed count, so no dust share outlives a debt that is gone; that is the
    ///      rule `repay` follows too.
    function _retireLoan(
        uint256 tokenId,
        MarketLedger.Loan memory loan,
        uint256 repaid,
        uint256 debt,
        bool fullSeizure
    ) private {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        uint256 shares =
            (fullSeizure || repaid == debt) ? loan.debtShares : DebtMath.sharesForRepay(repaid, $.borrowIndex);

        $.totalBorrowShares -= shares;
        $.poolDebtShares[loan.poolKeyId] -= shares;
        $.totalBorrows = DebtMath.debtOf($.totalBorrowShares, $.borrowIndex);

        if (fullSeizure) delete $.loans[tokenId];
        else $.loans[tokenId].debtShares -= shares;
    }

    /// @dev The two things a liquidation does to `reserves`, in the order §9 puts them: the
    ///      protocol's liquidation fee goes in, and bad debt comes back out of it.
    ///
    ///      Bad debt takes **all** of the reserve if it needs it, the part below the §7
    ///      withdrawal floor included — the floor limits what the owner may take out, not what
    ///      the buffer is for. The debt itself is already off `totalBorrows`; reserve and debt
    ///      fall together, so the covered part leaves `totalAssets` untouched and no lender
    ///      notices. What the reserve cannot cover has nothing to fall against, so it lands on
    ///      `totalAssets` and the share price of this market's depositors drops. That part, and
    ///      only that part, is what the market reports as `BadDebtSocialized`.
    function _settleReserves(
        uint256 protocolFee,
        uint256 badDebt
    ) private returns (uint256 socialized) {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        uint256 reserves = $.reserves + protocolFee;
        uint256 covered = Math.min(reserves, badDebt);

        $.reserves = reserves - covered;
        return badDebt - covered;
    }

    /// @dev Steps 1 and 2: value the position at liquidation prices, refuse it if it is still
    ///      healthy, and work out the seizure its terms allow.
    ///
    ///      **Two valuations come out of one reading, and telling them apart is what this
    ///      function is for** (§4.1, from the PR #7 review). The health factor asks whether the
    ///      position is underwater, and uses `collateralValue`: fees capped at 10% of
    ///      principal, after haircut (§6.2). The seizure asks what is actually there to hand
    ///      over, and uses the realizable value: principal plus **all** fees, after haircut
    ///      (§5.1, §8 step 1). Seizing against the capped number would take less than the
    ///      position holds and bring bad debt forward.
    ///
    ///      Both the collateral and the debt are priced through `priceForLiquidation`, so
    ///      nothing on this path reads the surface the §5.2 borrow gates guard. That is the
    ///      property those gates depend on: they stop borrowing without ever stopping a
    ///      liquidation, so an underwater position is never unclearable.
    function _plan(
        Env memory env,
        Request memory r,
        MarketLedger.Loan memory loan,
        uint256 debt
    ) private view returns (Context memory c) {
        ICollateralPolicy.Terms memory terms = env.policy.termsOf(loan.poolKeyId);
        IPositionValuer.Valuation memory v = env.valuer.valueForLiquidation(r.tokenId);

        // §6.3: a hook that skims on withdrawal takes its cut out of everything that leaves,
        // fees included, so one factor applies to every part of the valuation.
        uint256 keepBps = BPS - terms.removeHaircutBps;
        c.feeUsd = v.feesUsd * keepBps / BPS;
        c.fee0 = v.fees0 * keepBps / BPS;
        c.fee1 = v.fees1 * keepBps / BPS;

        c.usdgPrice = env.oracle.priceForLiquidation(Currency.wrap(env.asset));
        c.usdgDecimals = env.oracle.decimals(Currency.wrap(env.asset));

        uint256 hf = LiquidationMath.healthFactor(
            v.principalUsd, v.feesUsd, terms.removeHaircutBps, terms.ltBps, debt, c.usdgPrice, c.usdgDecimals
        );
        if (hf >= WAD) revert PositionIsHealthy(r.tokenId, hf);

        c.plan = LiquidationMath.plan(
            LiquidationMath.Inputs({
                debt: debt,
                repayRequested: r.repayAmount,
                realizableUsd: (v.principalUsd + v.feesUsd) * keepBps / BPS,
                feeUsd: c.feeUsd,
                usdgPrice: c.usdgPrice,
                usdgDecimals: c.usdgDecimals,
                closeFactorBps_: LiquidationMath.closeFactorBps(loan.tier, hf, debt),
                bonusBps: terms.liquidatorBonusBps,
                liquidity: v.liquidity
            })
        );
    }

    /// @dev §8 step 4. `BURN_POSITION` decreases the position to zero before burning the token
    ///      — verified in `PositionManager._burn` — so no separate `DECREASE_LIQUIDITY` is
    ///      needed, and everything it realises, fees included, belongs to the liquidator.
    ///      `TAKE_PAIR` may therefore address them directly, native ETH and all.
    ///
    ///      Slippage is checked by the market rather than passed into the burn: the caller's
    ///      minimums are written against what they receive, and on the other branch that is
    ///      not the number PositionManager would check.
    ///
    ///      The amounts are `to`'s balance change across the burn, so a contract `to` can move
    ///      them: redeem vault shares when the ETH arrives, or forward the ETH elsewhere. That
    ///      misstates only its own receipt, only in `Liquidate`, and nothing in the ledger reads
    ///      it (review of PR #16).
    function _seizeWholePosition(
        Env memory env,
        Request memory r,
        PoolKey memory key
    ) private returns (uint256 out0, uint256 out1) {
        out0 = key.currency0.balanceOf(r.to);
        out1 = key.currency1.balanceOf(r.to);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(r.tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, r.to);
        _run(env, abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR)), params);

        out0 = key.currency0.balanceOf(r.to) - out0;
        out1 = key.currency1.balanceOf(r.to) - out1;
    }

    /// @dev §8 step 5. The slice is taken into the market first and split here, because a
    ///      decrease realises the position's whole fee balance however little liquidity it
    ///      pulls. A `TAKE_PAIR` addressed straight to the liquidator would hand them every fee
    ///      in the position for the price of a one-wei repay — the v0.2 gap, closed in v0.3,
    ///      and the reason this cannot reuse `decreaseLiquidity` (FAR-8), which pays its caller.
    ///
    ///      The liquidator is owed everything that arrived minus the borrower's share of the
    ///      fees, which is only non-zero when the fees outrun the seizure allowance. The split is
    ///      measured per currency from the fee amounts read before the call, so a position
    ///      whose fees sit mostly on one side does not pay them out on the other.
    ///
    ///      Nothing leaves here: `execute` writes the ledger first, then `_payOut` moves tokens.
    function _takeSlice(
        Env memory env,
        Request memory r,
        Context memory c,
        PoolKey memory key
    ) private returns (Split memory s) {
        uint256 in0 = key.currency0.balanceOfSelf();
        uint256 in1 = key.currency1.balanceOfSelf();

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(r.tokenId, uint256(c.plan.liqToRemove), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        _run(env, abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);

        in0 = key.currency0.balanceOfSelf() - in0;
        in1 = key.currency1.balanceOfSelf() - in1;

        s.keep0 = LiquidationMath.retainedFee(in0, c.fee0, c.feeUsd, c.plan.feeCredit);
        s.keep1 = LiquidationMath.retainedFee(in1, c.fee1, c.feeUsd, c.plan.feeCredit);
        s.out0 = in0 - s.keep0;
        s.out1 = in1 - s.keep1;
    }

    /// @notice Where a partial seizure's tokens are owed, per currency, and what the fees the
    ///         seizure was not entitled to did to the debt.
    /// @param out0 currency0 owed to the liquidator.
    /// @param out1 currency1 owed to the liquidator.
    /// @param keep0 currency0 owed back to the borrower.
    /// @param keep1 currency1 owed back to the borrower.
    /// @param applied The borrower's own USDG fees, spent on their debt.
    /// @param cost USDG the liquidator pays for the non-USDG fee leg it has to buy.
    struct Split {
        uint256 out0;
        uint256 out1;
        uint256 keep0;
        uint256 keep1;
        uint256 applied;
        uint256 cost;
    }

    /// @dev What happens to the fees the seizure was not entitled to (§8 step 5, v0.26).
    ///
    ///      The USDG leg is already in the market, so spending it on the remaining debt is a
    ///      ledger entry. The other leg could only reach the debt through a swap the core
    ///      protocol does not make (§4.7), so while debt remains the liquidator buys it at
    ///      `priceForLiquidation`, with no bonus and no protocol fee, and that USDG repays the
    ///      debt. Only what the debt cannot absorb goes back to the borrower.
    ///
    ///      The purchase is paid from what `repayAmount` leaves after `repay`, and a shortfall
    ///      reverts rather than hand the leg back. Handing it back is what let a 1-wei repay
    ///      move collateral out to a borrower still in debt and push the health factor down on
    ///      demand (review of PR #16). Worth knowing: `repay` is `repayAmount` capped by the
    ///      close factor, so a budget is left over only once `repay` sits at that cap. On a
    ///      position whose fees outrun a smaller seizure, a liquidator goes to the close factor
    ///      or does not liquidate.
    ///
    ///      Every pool is quoted in the borrow asset (§6.1), so exactly one leg is USDG.
    function _settleRetainedFees(
        Env memory env,
        Request memory r,
        Context memory c,
        PoolKey memory key,
        Split memory s,
        uint256 remainingDebt
    ) private view {
        bool usdgIs0 = Currency.unwrap(key.currency0) == env.asset;
        (uint256 usdgKept, uint256 otherKept) = usdgIs0 ? (s.keep0, s.keep1) : (s.keep1, s.keep0);

        s.applied = Math.min(usdgKept, remainingDebt);
        uint256 bought;
        if (otherKept != 0 && remainingDebt != s.applied) {
            (bought, s.cost) = _priceFeeLeg(
                env, c, key, usdgIs0 ? key.currency1 : key.currency0, otherKept, remainingDebt - s.applied
            );
            if (r.repayAmount - c.plan.repay < s.cost) {
                revert FeePurchaseUnderfunded(s.cost, r.repayAmount - c.plan.repay);
            }
        }

        if (usdgIs0) {
            (s.keep0, s.keep1, s.out1) = (usdgKept - s.applied, otherKept - bought, s.out1 + bought);
        } else {
            (s.keep1, s.keep0, s.out0) = (usdgKept - s.applied, otherKept - bought, s.out0 + bought);
        }
    }

    function _priceFeeLeg(
        Env memory env,
        Context memory c,
        PoolKey memory key,
        Currency currency,
        uint256 amount,
        uint256 remainingDebt
    ) private view returns (uint256, uint256) {
        return LiquidationMath.purchase(
            amount,
            env.oracle.priceForLiquidation(currency, key),
            env.oracle.decimals(currency),
            c.usdgPrice,
            c.usdgDecimals,
            remainingDebt
        );
    }

    /// @dev Pays out a partial seizure once the ledger already records it.
    ///
    ///      The borrow asset goes first. Until it has left it is cash in `totalAssets` that the
    ///      ledger no longer stands behind, and the transfers after it can run the recipient's
    ///      code — native ETH always does.
    function _payOut(
        Env memory env,
        Request memory r,
        PoolKey memory key,
        address borrower,
        Split memory s
    ) private {
        if (Currency.unwrap(key.currency1) == env.asset) {
            _pay(env, key.currency1, r.to, s.out1, borrower, s.keep1);
            _pay(env, key.currency0, r.to, s.out0, borrower, s.keep0);
        } else {
            _pay(env, key.currency0, r.to, s.out0, borrower, s.keep0);
            _pay(env, key.currency1, r.to, s.out1, borrower, s.keep1);
        }
    }

    /// @dev The liquidator's leg is a plain transfer. `to` is theirs to choose, and a recipient
    ///      that refuses its own payout only fails its own call.
    ///
    ///      The borrower's leg is different: it is the one transfer a borrower could use to make
    ///      itself unliquidatable. A contract that reverts on ETH, or burns whatever gas it is
    ///      handed, would take the liquidation down with it. Since v0.26 anything goes back to
    ///      the borrower only once the fees outrun both the seizure and the whole remaining
    ///      debt, and no choice of `repayAmount` avoids that. Native ETH is therefore offered with a fixed
    ///      gas stipend, and if it is refused it is wrapped and sent as WETH, which runs none of
    ///      the borrower's code. The WETH is PositionManager's own, so nothing here names a
    ///      chain (§14).
    function _pay(
        Env memory env,
        Currency currency,
        address liquidator,
        uint256 toLiquidator,
        address borrower,
        uint256 toBorrower
    ) private {
        if (toLiquidator != 0) currency.transfer(liquidator, toLiquidator);
        if (toBorrower == 0) return;
        if (Currency.unwrap(currency) != address(0)) {
            // A token's issuer can stop an address receiving it (USDG has `isFrozen`), and a
            // reverting transfer would take the liquidation down with it. What cannot be
            // delivered stays in the market, and the borrower's claim to it is gone (§8 step 5,
            // v0.38, option A). USDG becomes cash that `totalAssets` counts, so the excess falls
            // to the market's depositors. Any other ERC-20 leg is counted by nothing and has no
            // way out: §4.1 has no ERC-20 rescue. That case is real: §6.3 screens out pausable
            // and blacklisting tokens, but not per-wallet caps or anti-bot rules, which refuse a
            // transfer to an ordinary address.
            IERC20(Currency.unwrap(currency)).trySafeTransfer(borrower, toBorrower);
            return;
        }

        bool sent;
        assembly ("memory-safe") {
            // No return data is copied, so the borrower cannot bill this call for that either.
            sent := call(BORROWER_ETH_GAS, borrower, toBorrower, 0, 0, 0, 0)
        }
        if (sent) return;

        IWETH9 weth = INativeWrapper(address(env.positionManager)).WETH9();
        weth.deposit{value: toBorrower}();
        IERC20(address(weth)).safeTransfer(borrower, toBorrower);
    }

    function _run(
        Env memory env,
        bytes memory actions,
        bytes[] memory params
    ) private {
        env.positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }
}
