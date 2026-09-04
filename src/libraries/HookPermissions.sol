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
///      Farmenta only cares about one question: can this hook interfere with pulling
///      liquidity back out? That is the operation both `liquidate` and `withdrawCollateral`
///      depend on, so a hook able to block it or skim from it can strand collateral or make
///      a loan unliquidatable.
library HookPermissions {
    /// @notice The three callbacks that can interfere with removing liquidity.
    /// @dev Built from v4-core's own flags rather than the literal 0x301 that
    ///      ARCHITECTURE §6.1 quotes: if Uniswap ever renumbers a bit, this mask follows and
    ///      a hard-coded constant would silently start admitting the wrong hooks.
    ///      `test_maskMatchesTheSpec` pins the two together.
    uint160 internal constant REMOVE_LIQUIDITY_MASK = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;

    /// @notice True if the hook implements none of the remove-liquidity callbacks.
    /// @dev A `true` here is not admission on its own. Since v0.5 every pool is listed
    ///      explicitly (§6.1), so this is a precondition of review, not a gate: a hook that
    ///      passes still needs the pool listed, and a hook that fails can still be listed via
    ///      `hookAllowlist` once someone has read its source (§6.3).
    function leavesRemoveLiquidityAlone(
        IHooks hooks
    ) internal pure returns (bool) {
        return uint160(address(hooks)) & REMOVE_LIQUIDITY_MASK == 0;
    }
}
