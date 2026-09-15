// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DebtMath} from "../../src/libraries/DebtMath.sol";
import {LiquidationMath} from "../../src/libraries/LiquidationMath.sol";

/// @notice Drives `LiquidationMath.plan` over arbitrary positions and records what came out.
/// @dev Violations go into ghost variables rather than `assert`s in this handler, because an
///      assert here would enforce nothing: with `fail_on_revert = false` a failing assert
///      reverts the call and Foundry discards it as an unused one, leaving the suite green
///      (§7, corrected v0.21 after PR #12 proved it). The `invariant_` functions below read
///      these instead.
contract LiquidationPlanHandler is Test {
    uint256 internal constant BPS = 10_000;

    /// @notice Value the liquidator was entitled to, beyond `repay × (1 + bonus)`.
    uint256 public worstOvershoot;

    /// @notice A plan asked for more liquidity than the position had.
    bool public sawLiquiditySliceTooLarge;

    /// @notice A capped repay still bought a seizure larger than the position.
    bool public sawSeizurePastThePosition;

    /// @notice A protocol fee that was not a tenth of the bonus on the repay.
    bool public sawWrongProtocolFee;

    /// @notice A repay beyond what the close factor allows.
    bool public sawRepayPastTheCloseFactor;

    /// @notice How many plans were actually built. Read by an invariant, so a suite that
    ///         bounded itself into reverting everything cannot pass by doing nothing.
    uint256 public plansBuilt;

    /// @param realizableUsd What the position is worth, principal + all fees after haircut.
    /// @param feeShareBps How much of that value is uncollected fees.
    function planSeizure(
        uint256 realizableUsd,
        uint16 feeShareBps,
        uint256 repayRequested,
        uint256 debt,
        uint16 bonusBps,
        uint16 closeFactorBps,
        uint128 liquidity,
        uint256 usdgPrice
    ) external {
        LiquidationMath.Inputs memory i = LiquidationMath.Inputs({
            // Up to a trillion dollars and a trillion USDG: far past anything §6.2's caps
            // allow, and still clear of the range where the intermediate products overflow.
            realizableUsd: bound(realizableUsd, 0, 1e30),
            feeUsd: 0,
            debt: bound(debt, 0, 1e18),
            repayRequested: 0,
            usdgPrice: bound(usdgPrice, 0.9e18, 1.1e18),
            usdgDecimals: 6,
            closeFactorBps_: uint16(bound(closeFactorBps, 1, BPS)),
            bonusBps: uint16(bound(bonusBps, 0, 5000)),
            liquidity: liquidity
        });
        i.feeUsd = i.realizableUsd * bound(feeShareBps, 0, BPS) / BPS;
        i.repayRequested = bound(repayRequested, 0, i.debt * 2);

        LiquidationMath.Plan memory p = LiquidationMath.plan(i);
        ++plansBuilt;

        if (p.repay > i.debt * i.closeFactorBps_ / BPS) sawRepayPastTheCloseFactor = true;
        if (p.protocolFee != p.repay * (i.bonusBps / 10) / BPS) sawWrongProtocolFee = true;

        if (p.fullSeizure) {
            // The branch exists so the liquidator never pays for more than can be handed over.
            if (p.seizeValue > i.realizableUsd) sawSeizurePastThePosition = true;
            return;
        }

        if (p.liqToRemove > i.liquidity) sawLiquiditySliceTooLarge = true;
        _recordPayout(i, p);
    }

    /// @dev What the plan entitles the liquidator to, valued the way §8 values it: the fee
    ///      credit, plus the principal the liquidity slice stands for. Both are floors, so the
    ///      real payout cannot be larger than this — `retainedFee` rounds the borrower's share
    ///      up, and Uniswap rounds a withdrawal down.
    function _recordPayout(
        LiquidationMath.Inputs memory i,
        LiquidationMath.Plan memory p
    ) private {
        uint256 principalUsd = i.realizableUsd - i.feeUsd;
        uint256 payout = p.feeCredit;
        if (i.liquidity != 0) payout += Math.mulDiv(p.liqToRemove, principalUsd, i.liquidity);

        uint256 ceiling = DebtMath.debtUsd(p.repay, i.usdgPrice, i.usdgDecimals) * (BPS + i.bonusBps) / BPS;
        if (payout > ceiling && payout - ceiling > worstOvershoot) worstOvershoot = payout - ceiling;
    }
}

/// @notice §8 step 5's payout ceiling, as an invariant over every seizure the arithmetic can
///         produce: whatever the liquidator asks to repay, against whatever mix of fees and
///         liquidity, they are never entitled to more than `repay × (1 + bonus)`.
/// @dev Deliberately in the fast lane, over the pure arithmetic rather than a forked position.
///      The end-to-end version — real pool, real withdrawal, real token balances — is
///      `MarketLiquidateForkTest.testFuzz_theLiquidatorNeverReceivesMoreThanTheBonus`, and it
///      can only fuzz one position's shape. This one reaches the shapes that position cannot
///      have: all fees and no principal, no fees at all, a bonus of zero, a close factor that
///      binds first, a USDG off its peg.
contract MarketLiquidateInvariantTest is Test {
    LiquidationPlanHandler internal handler;

    function setUp() public {
        handler = new LiquidationPlanHandler();
        targetContract(address(handler));
    }

    function invariant_theLiquidatorIsNeverEntitledToMoreThanTheBonus() public view {
        assertEq(handler.worstOvershoot(), 0, "a seizure was worth more than repay x (1 + bonus)");
    }

    function invariant_theSliceNeverExceedsThePosition() public view {
        assertFalse(handler.sawLiquiditySliceTooLarge(), "a plan asked for more liquidity than the position held");
    }

    function invariant_aCappedRepayNeverSeizesPastThePosition() public view {
        assertFalse(handler.sawSeizurePastThePosition(), "the step 2 cap let a seizure outgrow the position");
    }

    function invariant_theProtocolFeeStaysATenthOfTheBonus() public view {
        assertFalse(handler.sawWrongProtocolFee(), "the protocol fee drifted from the pool's bonus");
    }

    function invariant_theCloseFactorAlwaysBinds() public view {
        assertFalse(handler.sawRepayPastTheCloseFactor(), "a repay went past the close factor");
    }

    /// @dev The suite's own smoke test. Ghost-variable invariants pass trivially when the
    ///      handler never ran, and bounds that revert everything are an easy way to get there.
    ///      It hangs off `afterInvariant` rather than being an `invariant_` of its own, because
    ///      Foundry checks every invariant once before the first call — when nothing has run
    ///      yet, and this one would always be failing at that moment.
    function afterInvariant() public view {
        assertGt(handler.plansBuilt(), 0, "no seizure was ever planned");
    }
}
