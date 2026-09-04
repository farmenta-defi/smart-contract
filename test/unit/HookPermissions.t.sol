// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {HookPermissions} from "../../src/libraries/HookPermissions.sol";
import {Fixtures} from "../base/Fixtures.sol";

/// @notice Unit tests for reading hook permissions from an address. No network.
contract HookPermissionsTest is Test {
    /// @notice Pins the mask built from Uniswap's flags to the literal the spec quotes.
    /// @dev §6.1 states the check as `uint160(hooks) & 0x301 == 0`. The library derives the
    ///      mask from v4-core instead of copying that number; this is the seam where the two
    ///      have to agree. If Uniswap renumbers a bit, this fails and the spec needs updating
    ///      — which is the correct outcome, rather than the code quietly diverging.
    function test_maskMatchesTheSpec() public pure {
        assertEq(HookPermissions.REMOVE_LIQUIDITY_MASK, 0x301, "mask no longer matches spec 6.1");
    }

    function test_noHookLeavesRemoveLiquidityAlone() public pure {
        assertTrue(HookPermissions.leavesRemoveLiquidityAlone(IHooks(address(0))));
    }

    /// @dev The four hooks classified as swap-only or initialize-only in §6.1. These are real
    ///      addresses in use on Robinhood Chain, so the classification is checked against the
    ///      chain's actual population rather than invented examples.
    function test_realSwapOnlyHooksPass() public pure {
        assertTrue(
            HookPermissions.leavesRemoveLiquidityAlone(IHooks(Fixtures.HOOK_ETH_USDG_DYN)),
            "largest ETH/USDG pool's hook should be swap-only"
        );
        assertTrue(HookPermissions.leavesRemoveLiquidityAlone(IHooks(Fixtures.HOOK_ETH_USDG_TS60)));
        assertTrue(HookPermissions.leavesRemoveLiquidityAlone(IHooks(Fixtures.HOOK_SOLO)));
        assertTrue(HookPermissions.leavesRemoveLiquidityAlone(IHooks(Fixtures.HOOK_POOLS_TRADE_INITIALIZER)));
    }

    /// @dev The two that touch remove-liquidity. Doppler implements `afterRemoveLiquidity`
    ///      and CashCat `beforeRemoveLiquidity`, so both need a human to read their source
    ///      before a pool of theirs can be listed (§6.3).
    function test_realRemoveLiquidityHooksFail() public pure {
        assertFalse(
            HookPermissions.leavesRemoveLiquidityAlone(IHooks(Fixtures.HOOK_DOPPLER)),
            "Doppler implements afterRemoveLiquidity"
        );
        assertFalse(
            HookPermissions.leavesRemoveLiquidityAlone(IHooks(Fixtures.HOOK_CASHCAT_V2)),
            "CashCatV2 implements beforeRemoveLiquidity"
        );
    }

    /// @dev Each of the three bits must fail on its own — a mask that only caught two of them
    ///      would still pass every test above, since the real hooks set more than one bit.
    function testFuzz_anySingleRemoveBitFails(
        uint160 base
    ) public pure {
        base = uint160(bound(base, 0, type(uint160).max)) & ~uint160(0x301);
        assertTrue(HookPermissions.leavesRemoveLiquidityAlone(IHooks(address(base))), "clean address rejected");

        assertFalse(HookPermissions.leavesRemoveLiquidityAlone(IHooks(address(base | (1 << 9)))), "bit 9 missed");
        assertFalse(HookPermissions.leavesRemoveLiquidityAlone(IHooks(address(base | (1 << 8)))), "bit 8 missed");
        assertFalse(HookPermissions.leavesRemoveLiquidityAlone(IHooks(address(base | 1))), "bit 0 missed");
    }

    /// @dev Bits Farmenta does not object to must not cause a rejection. A mask that was too
    ///      wide would quietly exclude most of the chain's hooked pools.
    function test_unrelatedBitsAreIgnored() public pure {
        uint160 swapAndDonate = (1 << 7) | (1 << 6) | (1 << 5) | (1 << 4) | (1 << 13) | (1 << 12) | (1 << 11)
            | (1 << 10) | (1 << 3) | (1 << 2) | (1 << 1);
        assertTrue(
            HookPermissions.leavesRemoveLiquidityAlone(IHooks(address(swapAndDonate))),
            "mask is too wide - it rejects callbacks Farmenta does not care about"
        );
    }
}
