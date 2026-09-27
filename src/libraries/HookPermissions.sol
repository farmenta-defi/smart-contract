// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookPermissions
/// @notice Reads a v4 hook's permissions straight out of its address.
/// @dev Uniswap encodes which callbacks a hook implements in the low 14 bits of its own
///      address, so what a hook is allowed to do can be known without calling it — and
///      without trusting it to answer honestly.
///
///      Farmenta asks two questions of a hook. Can it interfere with pulling liquidity back
///      out? That is the operation both `liquidate` and `withdrawCollateral` depend on, so a
///      hook able to block it or skim from it can strand collateral or make a loan
///      unliquidatable. And can it make whoever adds liquidity pay more? `mintAndDeposit` and
///      `increaseLiquidity` add liquidity on the borrower's behalf, bounded only by the
///      maxima the borrower signed, so a hook able to bill that addition (FAR-47), or to
///      choose the price it is made at (FAR-63), takes the borrower's tokens without adding a
///      cent to the collateral.
library HookPermissions {
    /// @notice The five callbacks that fail the bit check of ARCHITECTURE §6.1: the three
    ///         that can interfere with removing liquidity, the return delta on adding it, and
    ///         the callback that runs before an addition.
    /// @dev v4-core subtracts the hook's `afterAddLiquidity` delta from the caller's
    ///      (`callerDelta - hookDelta` in `Hooks.afterModifyLiquidity`), and PositionManager
    ///      checks its maxima against what is left. That is the bill through a delta.
    ///
    ///      `beforeAddLiquidity` is the bill through the price. `PoolManager.modifyLiquidity`
    ///      calls it before the pool reads its own price, `swap` asks only that the manager is
    ///      unlocked, and `noSelfCall` keeps the hook's callbacks from running on its own swap.
    ///      So the hook can swap its pool, let the addition be made at the price it left, and
    ///      swap back in `afterAddLiquidity` against the liquidity just added, inside the same
    ///      unlock and with no capital of its own (FAR-63).
    ///
    ///      `afterAddLiquidity` alone stays out of the mask. It runs once the amounts are fixed,
    ///      so without the delta flag it cannot bill the addition, and moving the price
    ///      afterwards does not change what the adder paid.
    ///
    ///      Built from v4-core's own flags rather than the literal 0xB03 that §6.1 quotes: if
    ///      Uniswap ever renumbers a bit, this mask follows and a hard-coded constant would
    ///      silently start admitting the wrong hooks. `test_maskMatchesTheSpec` pins the two
    ///      together.
    uint160 internal constant BIT_CHECK_MASK = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

    /// @notice True if the hook implements none of the callbacks in `BIT_CHECK_MASK`.
    /// @dev A `true` here is not admission on its own. Since v0.5 every pool is listed
    ///      explicitly (§6.1), so this is a precondition of review, not a gate: a hook that
    ///      passes still needs the pool listed, and a hook that fails can still be listed via
    ///      `hookAllowlist` once someone has read its source (§6.3).
    function passesBitCheck(
        IHooks hooks
    ) internal pure returns (bool) {
        return uint160(address(hooks)) & BIT_CHECK_MASK == 0;
    }

    /// @notice True if the hook may return a delta from `afterRemoveLiquidity`.
    /// @dev The before/after callbacks can block removal, but only this return-delta flag can
    ///      reduce the amount the position manager releases. A configured removal haircut
    ///      therefore needs this exact permission rather than merely any removal callback.
    function returnsRemoveLiquidityDelta(
        IHooks hooks
    ) internal pure returns (bool) {
        uint160 required = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        return uint160(address(hooks)) & required == required;
    }
}
