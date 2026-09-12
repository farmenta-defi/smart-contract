// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {DebtMath} from "./DebtMath.sol";
import {LiquidationMath} from "./LiquidationMath.sol";
import {MarketLedger} from "./MarketLedger.sol";

/// @title MarketLiquidation
/// @notice Everything a §8 seizure does that is not a write to the market's ledger.
/// @dev **A deployed library, called by `delegatecall`, and that is load-bearing twice over.**
///      It runs in the market's context, so `address(this)` is the market and `msg.sender` is
///      still the liquidator: the USDG pull, the `modifyLiquidities` call that only the NFT's
///      owner may make, and every payout all behave exactly as they would inside the market.
///      And its code lives at its own address, which is the reason this file exists at all —
///      `FarmentaMarket` had 1,474 bytes left under EIP-170 and this logic is about 5,000
///      (foundry.toml's `deploy` note predicted the squeeze and named the way out).
///
///      It writes the market's ledger too, through `MarketLedger` — the one declaration of
///      that layout, shared rather than copied, so the two compilation units cannot drift into
///      disagreeing about where a slot is. The market keeps the parts that have to be seen from
///      outside: the guard, the accrual, and every event.
library MarketLiquidation {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

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
    /// @param plan The seizure §8 allows.
    struct Context {
        uint256 feeUsd;
        uint256 fee0;
        uint256 fee1;
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

    /// @notice Runs §8 in full: value, gate, charge, seize, pay out, and settle the ledger.
    /// @dev The caller has already accrued interest and taken the reentrancy guard, and emits
    ///      the events from what this returns. Everything between is here.
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

        // Step 3. `msg.sender` survives the delegatecall, so this is the liquidator paying.
        IERC20(env.asset).safeTransferFrom(msg.sender, address(this), c.plan.repay + c.plan.protocolFee);
        o.fullSeizure = c.plan.fullSeizure;

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(r.tokenId);
        uint256 retainedUsdg;
        if (c.plan.fullSeizure) {
            (o.out0, o.out1) = _seizeWholePosition(env, r, key);
        } else {
            (o.out0, o.out1, retainedUsdg) = _seizeSlice(env, r, c, key, loan.owner);
        }
        // Measured on what the liquidator received, not on what reached the market: on the
        // partial branch those differ by exactly the borrower's share of the fees.
        if (o.out0 < r.minOut0 || o.out1 < r.minOut1) revert SeizureBelowMinimum(o.out0, o.out1);

        o.repaid = c.plan.repay + _applyRetainedUsdg(env, loan.owner, debt, c.plan.repay, retainedUsdg);
        if (c.plan.fullSeizure) o.badDebt = debt - o.repaid;

        // Step 6.
        _retireLoan(r.tokenId, loan, o.repaid, debt, o.fullSeizure);
        o.socialized = _settleReserves(c.plan.protocolFee, o.badDebt);
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

        uint256 usdgPrice = env.oracle.priceForLiquidation(Currency.wrap(env.asset));
        uint8 usdgDecimals = env.oracle.decimals(Currency.wrap(env.asset));

        uint256 hf = DebtMath.healthFactor(
            (v.principalUsd + Math.min(v.feesUsd, v.principalUsd / 10)) * keepBps / BPS,
            terms.ltBps,
            DebtMath.debtUsd(debt, usdgPrice, usdgDecimals)
        );
        if (hf >= WAD) revert PositionIsHealthy(r.tokenId, hf);

        c.plan = LiquidationMath.plan(
            LiquidationMath.Inputs({
                debt: debt,
                repayRequested: r.repayAmount,
                realizableUsd: (v.principalUsd + v.feesUsd) * keepBps / BPS,
                feeUsd: c.feeUsd,
                usdgPrice: usdgPrice,
                usdgDecimals: usdgDecimals,
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
    ///      The liquidator gets everything that arrived minus the borrower's share of the fees,
    ///      which is only non-zero when the fees outrun the seizure allowance. The split is
    ///      measured per currency from the fee amounts read before the call, so a position
    ///      whose fees sit mostly on one side does not pay them out on the other.
    function _seizeSlice(
        Env memory env,
        Request memory r,
        Context memory c,
        PoolKey memory key,
        address borrower
    ) private returns (uint256 out0, uint256 out1, uint256 retainedUsdg) {
        out0 = key.currency0.balanceOfSelf();
        out1 = key.currency1.balanceOfSelf();

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(r.tokenId, uint256(c.plan.liqToRemove), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        _run(env, abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);

        out0 = key.currency0.balanceOfSelf() - out0;
        out1 = key.currency1.balanceOfSelf() - out1;

        uint256 keep0 = LiquidationMath.retainedFee(out0, c.fee0, c.feeUsd, c.plan.feeCredit);
        uint256 keep1 = LiquidationMath.retainedFee(out1, c.fee1, c.feeUsd, c.plan.feeCredit);
        out0 -= keep0;
        out1 -= keep1;

        retainedUsdg = _returnToBorrower(env, borrower, key, keep0, keep1);
        if (out0 != 0) key.currency0.transfer(r.to, out0);
        if (out1 != 0) key.currency1.transfer(r.to, out1);
    }

    /// @dev Hands the borrower back the fees the seizure was not entitled to.
    ///
    ///      The borrow-asset leg stays in the market and is returned as a number, because §8
    ///      step 5 spends it on the debt before anything is paid out — and every pool is quoted
    ///      in that asset (§6.1), so there is exactly one such leg. The other currency can only
    ///      go back in kind; nothing in the core protocol swaps (§4.7).
    ///
    ///      That in-kind transfer is the one place a borrower can interfere with their own
    ///      liquidation: on a native-ETH pool a contract borrower that rejects ETH makes it
    ///      revert. It is reachable only when uncollected fees outrun the entire seizure
    ///      allowance, and a liquidator can step around it by repaying more. It is the same
    ///      open question as the ETH with no way out in `FarmentaMarket.receive()` (§15 no. 12)
    ///      and belongs in the spec rather than in a decision made here.
    function _returnToBorrower(
        Env memory env,
        address borrower,
        PoolKey memory key,
        uint256 keep0,
        uint256 keep1
    ) private returns (uint256 retainedUsdg) {
        if (Currency.unwrap(key.currency0) == env.asset) {
            (retainedUsdg, keep0) = (keep0, 0);
        } else if (Currency.unwrap(key.currency1) == env.asset) {
            (retainedUsdg, keep1) = (keep1, 0);
        }

        if (keep0 != 0) key.currency0.transfer(borrower, keep0);
        if (keep1 != 0) key.currency1.transfer(borrower, keep1);
    }

    /// @dev The borrower's own fees, spent on their remaining debt first and returned to them
    ///      beyond it (§8 step 5). The USDG is already in the market — it arrived with the
    ///      slice — so applying it to the debt is a ledger entry the caller makes, not a
    ///      transfer; only the excess moves.
    function _applyRetainedUsdg(
        Env memory env,
        address borrower,
        uint256 debt,
        uint256 repay,
        uint256 retainedUsdg
    ) private returns (uint256 applied) {
        if (retainedUsdg == 0) return 0;

        applied = Math.min(retainedUsdg, debt - repay);
        uint256 excess = retainedUsdg - applied;
        if (excess != 0) IERC20(env.asset).safeTransfer(borrower, excess);
    }

    function _run(
        Env memory env,
        bytes memory actions,
        bytes[] memory params
    ) private {
        env.positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }
}
