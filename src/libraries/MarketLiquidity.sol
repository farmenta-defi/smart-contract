// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {DebtMath} from "./DebtMath.sol";
import {MarketDebt} from "./MarketDebt.sol";
import {MarketLedger} from "./MarketLedger.sol";

/// @title MarketLiquidity
/// @notice Linked execution for what a borrower does to a position the market holds: claiming
///         its fees (FAR-7) and removing part of its liquidity (FAR-8). Adding liquidity (FAR-9) runs
///         from `MarketMint`, beside the Permit2 plumbing it shares with the mint.
/// @dev Runs by delegatecall, like `MarketDebt` and `MarketMint`. `address(this)` is the market,
///      which owns the NFT and is therefore the only caller PositionManager lets decrease it;
///      `msg.sender` is still the borrower. The market keeps the wrapper, the pause and the guard
///      (§4.1 v0.33).
library MarketLiquidity {
    /// @notice A position's fees were claimed to `to` (§4.1, `poolId` per v0.30).
    /// @dev `amount0`/`amount1` are `to`'s balance change across the claim, not the fees the position
    ///      realised. Anything else reaching `to` while its ETH callback runs is counted as well, a vault
    ///      redeem or a transfer from anyone, so indexers (§13) must not treat these figures as verified
    ///      fee income. A `to` that sends out more than it received during that callback makes the claim
    ///      revert with an arithmetic panic.
    event CollectFees(uint256 indexed tokenId, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /// @notice Liquidity left a position to `to` (§4.1, `poolId` per v0.30, field order per v0.43).
    event LiquidityChanged(uint256 indexed tokenId, PoolId indexed poolId, int256 liqDelta);

    error NotTheDepositor(uint256 tokenId, address depositor);
    error InvalidRecipient(address to);
    error ZeroLiquidity();
    error LiquidityExceedsPosition(uint256 tokenId, uint128 requested, uint128 available);
    error PositionBelowMinimum(uint256 principalUsd, uint256 minimumUsd);

    /// @notice The market's dependencies, which a delegatecall cannot read for itself.
    struct Env {
        IPositionManager positionManager;
        MarketDebt.Env debt;
    }

    /// @notice Claims every fee `tokenId` has accrued to `to`, and keeps the position healthy.
    /// @dev Uniswap v4 has no collect action. `_decrease` realises the position's whole fee
    ///      balance however little liquidity it removes, so a `DECREASE_LIQUIDITY` of zero pays
    ///      out exactly the fees and never principal. The fees may go to `to` directly, unlike §8
    ///      step 5's partial seizure, because they belong to the caller.
    ///
    ///      **The borrow asset leaves first** (§4.1 v0.26, v0.40). Each leg is its own `TAKE`, USDG
    ///      before the other. `TAKE_PAIR` would pay `currency0` first, which in a native-ETH pool is
    ///      the ETH, and ETH runs the recipient's code before the USDG has left. None of the
    ///      market's own cash moves on this path either way; the order is kept so that no function
    ///      is an exception to the rule.
    ///
    ///      **Recipients PositionManager would not actually pay are refused** (§4.1 v0.43). See
    ///      `refusesRecipient`.
    ///
    ///      **The health factor is checked after the claim, because the claim is what lowers it**
    ///      (§7). With debt outstanding, the check runs §5.2's borrow price gates first (v0.40):
    ///      the fees would otherwise leave at a price the gates refuse to lend against.
    ///
    ///      **Nothing is written after the first outbound call** (§4.1 v0.26). The only write is
    ///      the accrual, and it comes first. Pool hooks and a native-ETH `to` run code during the
    ///      claim, but the market's cash, debt and reserves do not move here at all: the fees come
    ///      from PoolManager. A vault redeem made from inside that code is priced on the same
    ///      ledger as one made after. The health check that follows only reads, and reverts the
    ///      whole claim if it fails.
    function collectFees(
        Env calldata env,
        uint256 tokenId,
        address to
    ) external {
        MarketDebt.accrue(env.debt);
        if (refusesRecipient(env.positionManager, to)) revert InvalidRecipient(to);

        MarketLedger.Loan storage loan = MarketLedger.layout().loans[tokenId];
        if (loan.owner != msg.sender) revert NotTheDepositor(tokenId, loan.owner);

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(tokenId);
        uint256 amount0 = key.currency0.balanceOf(to);
        uint256 amount1 = key.currency1.balanceOf(to);

        _decreaseTo(env, key, tokenId, 0, 0, 0, to);

        amount0 = key.currency0.balanceOf(to) - amount0;
        amount1 = key.currency1.balanceOf(to) - amount1;

        MarketDebt.requireHealthy(env.debt, tokenId);
        emit CollectFees(tokenId, loan.poolKeyId, amount0, amount1);
    }

    /// @dev `FarmentaMarket.decreaseLiquidity`'s arguments. Carried as one calldata struct so the
    ///      unoptimised `lite` build does not run out of stack slots.
    struct DecreaseParams {
        uint256 tokenId;
        uint128 liquidity;
        uint128 amount0Min;
        uint128 amount1Min;
        address to;
    }

    /// @notice Removes `p.liquidity` from `p.tokenId` to `p.to`, and leaves behind a position that
    ///         is still worth holding and still within its borrow limit.
    /// @dev The same `DECREASE_LIQUIDITY` and two `TAKE`s as `collectFees`, USDG first, with the
    ///      liquidity no longer zero. `_decrease` realises the position's whole fee balance
    ///      whatever it removes, so `to` receives the slice's principal **and every fee**. That is
    ///      right here, because the caller owns both. It is not right in §8's partial seizure, which
    ///      owes the fees of the unseized part back to the borrower: do not copy this into
    ///      `liquidate`.
    ///
    ///      **`amount0Min`/`amount1Min` bound the principal alone.** PositionManager checks them
    ///      against `liquidityDelta - feesAccrued`, so fees never help a removal clear its minimum,
    ///      and a caller sizes them from the slice's principal only.
    ///
    ///      **A zero `liquidity` is refused**: that is a fee claim, and `collectFees` is the function
    ///      for it, with its own event. **More than the position holds is refused here**, by name,
    ///      rather than deep inside PoolManager as an arithmetic failure.
    ///
    ///      **What stays in custody must still pass §6.1's minimum** (decided on FAR-8, 17 Sep 2026):
    ///      principal after the removal haircut, fees excluded, against the pool's
    ///      `minPositionUsd`, **owing or not**. `borrow` does not look at the floor again, so a
    ///      position allowed under it while debt-free could be borrowed against a moment later, and
    ///      dust is what no liquidator takes. The whole of a position therefore never leaves this
    ///      way: a borrower owing nothing takes the NFT back with `withdrawCollateral`. Measured
    ///      after the removal, on the position as it now is.
    ///
    ///      **With debt outstanding, what is owed must still fit the borrow limit of what is left**
    ///      (§4.1 v0.59, decided on the review of PR #23), read through §5.2's borrow price gates
    ///      (decided on FAR-8, 17 Sep 2026). Principal leaving lowers the health factor exactly as a
    ///      borrow does, so it is held to a borrow's limit and refused at the prices a borrow is;
    ///      a health factor of 1 would let a removal walk a loan from `maxLtvBps` up to the
    ///      liquidation threshold. See `MarketDebt.requireWithinBorrowLimit`. With nothing owed
    ///      neither runs. A pool's `removeHaircutBps` is inside that value already (§6.2), applied
    ///      to what remains.
    ///
    ///      A frozen or delisted pool does not stop a removal (§6.5): only its terms are read.
    ///
    ///      **Nothing is written after the first outbound call** (§4.1 v0.26). The only write is
    ///      the accrual, and it comes first; on a meme market the TWAP observation follows it, before
    ///      PositionManager is called. The removal moves none of the market's cash, debt or
    ///      reserves: both legs go from PoolManager to `to`. Pool hooks and a native-ETH `to` run
    ///      code meanwhile, and a vault redeem made from there is priced on the same ledger as one
    ///      made after. The two checks that follow only read, and revert the whole removal.
    function decreaseLiquidity(
        Env calldata env,
        DecreaseParams calldata p
    ) external {
        if (p.liquidity == 0) revert ZeroLiquidity();
        MarketDebt.accrue(env.debt);
        if (refusesRecipient(env.positionManager, p.to)) revert InvalidRecipient(p.to);

        MarketLedger.Layout storage $ = MarketLedger.layout();
        MarketLedger.Loan storage loan = $.loans[p.tokenId];
        if (loan.owner != msg.sender) revert NotTheDepositor(p.tokenId, loan.owner);

        uint128 available = env.positionManager.getPositionLiquidity(p.tokenId);
        if (p.liquidity > available) revert LiquidityExceedsPosition(p.tokenId, p.liquidity, available);

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(p.tokenId);
        // §5.3: every market transaction touching a meme pool records an observation first, which
        // is also what the health check below prices the position through. Placed after the checks
        // above so a refusal names its own reason rather than `TwapUnavailable`.
        if ($.tier == ICollateralPolicy.Tier.MEME) env.debt.oracle.record(key);

        _decreaseTo(env, key, p.tokenId, p.liquidity, p.amount0Min, p.amount1Min, p.to);

        ICollateralPolicy.Terms memory terms = env.debt.policy.termsOf(loan.poolKeyId);
        uint256 recoverableUsd =
            DebtMath.recoverablePrincipal(env.debt.valuer.value(p.tokenId).principalUsd, terms.removeHaircutBps);
        if (recoverableUsd < terms.minPositionUsd) revert PositionBelowMinimum(recoverableUsd, terms.minPositionUsd);

        MarketDebt.requireWithinBorrowLimit(env.debt, p.tokenId);
        emit LiquidityChanged(p.tokenId, loan.poolKeyId, -int256(uint256(p.liquidity)));
    }

    /// @dev One `DECREASE_LIQUIDITY` paid straight to `to`, each leg by its own `TAKE` with the borrow
    ///      asset first (§4.1 v0.26, v0.40). Whatever `liquidity` is, the decrease realises the
    ///      position's whole fee balance as well, so both `TAKE`s carry principal and fees together.
    ///      The minimums are PositionManager's: it holds them against the principal alone.
    function _decreaseTo(
        Env calldata env,
        PoolKey memory key,
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        address to
    ) private {
        (Currency first, Currency second) = Currency.unwrap(key.currency1) == address(env.debt.asset)
            ? (key.currency1, key.currency0)
            : (key.currency0, key.currency1);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(first, to, uint256(ActionConstants.OPEN_DELTA));
        params[2] = abi.encode(second, to, uint256(ActionConstants.OPEN_DELTA));
        env.positionManager
            .modifyLiquidities(
                abi.encode(
                    abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE), uint8(Actions.TAKE)),
                    params
                ),
                block.timestamp
            );
    }

    /// @notice Whether `to` is refused as the recipient of a payout PositionManager makes for this
    ///         market (§4.1 v0.43, decided on PR #18).
    /// @dev One rule for every such payout: `collectFees` here, `decreaseLiquidity` (FAR-8), and both
    ///      branches of `liquidate` (FAR-46), which is why it is `internal` and shared rather than
    ///      written into each function.
    ///
    ///      - `address(0)`: nowhere.
    ///      - This market: the payout would sit here, where `rescueUnaccountedEth` sweeps ETH and no
    ///        ERC-20 has a way out.
    ///      - `address(1)`: `TAKE` reads it as its caller, which is this market again.
    ///      - `address(2)` and PositionManager itself: the payout stays in PositionManager's balance,
    ///        and anyone can take it with `SWEEP` (proved on a fork in the review of PR #18).
    function refusesRecipient(
        IPositionManager positionManager,
        address to
    ) internal view returns (bool) {
        return
            uint160(to) <= uint160(ActionConstants.ADDRESS_THIS) || to == address(this)
                || to == address(positionManager);
    }
}
