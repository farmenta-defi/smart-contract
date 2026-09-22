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
///      unliquidatable. And can it charge whoever adds liquidity? `mintAndDeposit` and
///      `increaseLiquidity` add liquidity on the borrower's behalf, bounded only by the
///      maxima the borrower signed, so a hook able to bill that addition takes the borrower's
///      tokens without adding a cent to the collateral (FAR-47).
library HookPermissions {
    /// @notice The four callbacks that fail the bit check of ARCHITECTURE §6.1: the three
    ///         that can interfere with removing liquidity, plus the return delta on adding it.
    /// @dev v4-core subtracts the hook's `afterAddLiquidity` delta from the caller's
    ///      (`callerDelta - hookDelta` in `Hooks.afterModifyLiquidity`), and PositionManager
    ///      checks its maxima against what is left. `afterAddLiquidity` without the delta
    ///      flag can observe an addition but cannot bill it, so it stays out of the mask.
    ///
    ///      Built from v4-core's own flags rather than the literal 0x303 that §6.1 quotes: if
    ///      Uniswap ever renumbers a bit, this mask follows and a hard-coded constant would
    ///      silently start admitting the wrong hooks. `test_maskMatchesTheSpec` pins the two
    ///      together.
    uint160 internal constant BIT_CHECK_MASK = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;

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
