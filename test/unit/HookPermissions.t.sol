// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {HookPermissions} from "../../src/libraries/HookPermissions.sol";
import {Fixtures} from "../base/Fixtures.sol";

/// @notice Unit tests for reading hook permissions from an address. No network.
contract HookPermissionsTest is Test {
    /// @notice Pins the mask built from Uniswap's flags to the literal the spec quotes.
    /// @dev §6.1 states the check as `uint160(hooks) & 0x303 == 0` (0x301 before FAR-47). The library derives the
    ///      mask from v4-core instead of copying that number; this is the seam where the two
    ///      have to agree. If Uniswap renumbers a bit, this fails and the spec needs updating
    ///      — which is the correct outcome, rather than the code quietly diverging.
    function test_maskMatchesTheSpec() public pure {
        assertEq(HookPermissions.BIT_CHECK_MASK, 0x303, "mask no longer matches spec 6.1");
    }

    function test_noHookPassesTheBitCheck() public pure {
        assertTrue(HookPermissions.passesBitCheck(IHooks(address(0))));
    }

    /// @dev The four hooks classified as swap-only or initialize-only in §6.1. These are real
    ///      addresses in use on Robinhood Chain, so the classification is checked against the
    ///      chain's actual population rather than invented examples.
    function test_realSwapOnlyHooksPass() public pure {
        assertTrue(
            HookPermissions.passesBitCheck(IHooks(Fixtures.HOOK_ETH_USDG_DYN)),
            "largest ETH/USDG pool's hook should be swap-only"
        );
        assertTrue(HookPermissions.passesBitCheck(IHooks(Fixtures.HOOK_ETH_USDG_TS60)));
        assertTrue(HookPermissions.passesBitCheck(IHooks(Fixtures.HOOK_SOLO)));
        assertTrue(HookPermissions.passesBitCheck(IHooks(Fixtures.HOOK_POOLS_TRADE_INITIALIZER)));
    }

    /// @dev The two that touch remove-liquidity. Doppler implements `afterRemoveLiquidity`
    ///      and CashCat `beforeRemoveLiquidity`, so both need a human to read their source
    ///      before a pool of theirs can be listed (§6.3).
    function test_realRemoveLiquidityHooksFail() public pure {
        assertFalse(
            HookPermissions.passesBitCheck(IHooks(Fixtures.HOOK_DOPPLER)), "Doppler implements afterRemoveLiquidity"
        );
        assertFalse(
            HookPermissions.passesBitCheck(IHooks(Fixtures.HOOK_CASHCAT_V2)),
            "CashCatV2 implements beforeRemoveLiquidity"
        );
    }

    function test_removeDeltaRequiresTheAfterRemoveLiquidityCallback() public pure {
        assertFalse(
            HookPermissions.returnsRemoveLiquidityDelta(IHooks(address(1))), "a delta flag without its callback passed"
        );
        assertFalse(
            HookPermissions.returnsRemoveLiquidityDelta(IHooks(address(1 << 8))),
            "an after callback without delta passed"
        );
        assertTrue(
            HookPermissions.returnsRemoveLiquidityDelta(IHooks(address(0x101))), "the complete delta hook was rejected"
        );
    }

    /// @dev Each of the four bits must fail on its own: a mask that missed one of them would
    ///      still pass every test above, since the real hooks set more than one bit.
    function testFuzz_anySingleMaskedBitFails(
        uint160 base
    ) public pure {
        base = uint160(bound(base, 0, type(uint160).max)) & ~uint160(0x303);
        assertTrue(HookPermissions.passesBitCheck(IHooks(address(base))), "clean address rejected");

        assertFalse(HookPermissions.passesBitCheck(IHooks(address(base | (1 << 9)))), "bit 9 missed");
        assertFalse(HookPermissions.passesBitCheck(IHooks(address(base | (1 << 8)))), "bit 8 missed");
        assertFalse(HookPermissions.passesBitCheck(IHooks(address(base | 1))), "bit 0 missed");
        assertFalse(HookPermissions.passesBitCheck(IHooks(address(base | (1 << 1)))), "bit 1 missed");
    }

    /// @dev Bits Farmenta does not object to must not cause a rejection. A mask that was too
    ///      wide would quietly exclude most of the chain's hooked pools. Bit 1 left this set in
    ///      FAR-47; `afterAddLiquidity` (bit 10) stays, since without its delta flag it cannot
    ///      bill the addition it observes.
    function test_unrelatedBitsAreIgnored() public pure {
        uint160 swapAndDonate = (1 << 7) | (1 << 6) | (1 << 5) | (1 << 4) | (1 << 13) | (1 << 12) | (1 << 11)
            | (1 << 10) | (1 << 3) | (1 << 2);
        assertTrue(
            HookPermissions.passesBitCheck(IHooks(address(swapAndDonate))),
            "mask is too wide - it rejects callbacks Farmenta does not care about"
        );
    }
}
