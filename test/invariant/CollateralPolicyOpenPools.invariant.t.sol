// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";

/// @notice Drives the switches that open and close a pool: the freeze, the two tokens and the
///         hook allowlist, from the owner's key and from the guardian's (FAR-74).
/// @dev A campaign of its own rather than more actions on `PolicyHandler`. That campaign speaks
///      about open pools, and with tokens and hooks switching as well its pools are closed for
///      most of a run: measured over 24 seeds, 7 runs ended with a pool still open, against 24
///      of 24 before. Terms and ramps are left out here because they read neither switch.
///
///      The handler is the owner, as in `PolicyHandler`, and pranks the guardian where an
///      action is the guardian's.
contract OpenPoolsHandler is Test {
    uint256 internal constant MAX_POOLS = 6;

    address public constant GUARDIAN = address(0x6A4D);

    CollateralPolicy public policy;
    PoolKey[] public keys;

    /// @dev Set when switching a token or a hook changed a listing record. A ghost, not an
    ///      assertion: with `fail_on_revert = false` a failed assertion in a handler is one
    ///      more revert, and the campaign stays green.
    bool public aSwitchRewroteAListing;

    constructor(
        CollateralPolicy policy_
    ) {
        policy = policy_;
    }

    /// @dev `hookSeed` picks what the pool sits behind: no hook, a hook the bit check admits,
    ///      or one that only the allowlist admits. The listing is refused while a token is
    ///      disabled or that last hook is not allowlisted, as it should be.
    function listPool(
        uint256 hookSeed
    ) public {
        if (keys.length >= MAX_POOLS) return;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.WETH),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: uint24(keys.length + 1),
            tickSpacing: int24(uint24(keys.length + 1)),
            hooks: IHooks(_pickHook(hookSeed))
        });

        TierPresets.Preset memory preset = TierPresets.blueChip();
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: preset.minPositionUsd
            })
        );
        keys.push(key);
    }

    function setFrozen(
        uint256 idx,
        bool frozen
    ) public {
        policy.setFrozen(keys[idx % keys.length].toId(), frozen);
    }

    function guardianFreeze(
        uint256 idx
    ) public {
        vm.prank(GUARDIAN);
        policy.freeze(keys[idx % keys.length].toId());
    }

    /// @dev Either token, by the guardian's `disableToken` or by the owner's `setTokenConfig`.
    function disableToken(
        uint256 tokenSeed,
        bool asGuardian
    ) public {
        Currency currency = _pickToken(tokenSeed);
        bytes32 listings = _listingsHash();

        if (asGuardian) {
            vm.prank(GUARDIAN);
            policy.disableToken(currency);
        } else {
            _setEnabled(currency, false);
        }

        if (_listingsHash() != listings) aSwitchRewroteAListing = true;
    }

    /// @dev Both tokens at once, so that a disable is undone about as often as it is done.
    function enableTokens() public {
        bytes32 listings = _listingsHash();

        _setEnabled(Currency.wrap(RobinhoodChain.WETH), true);
        _setEnabled(Currency.wrap(RobinhoodChain.USDG), true);

        if (_listingsHash() != listings) aSwitchRewroteAListing = true;
    }

    function revokeHook(
        uint256 hookSeed,
        bool asGuardian
    ) public {
        address hooks = _pickHook(hookSeed);
        bytes32 listings = _listingsHash();

        if (asGuardian) {
            vm.prank(GUARDIAN);
            policy.revokeHook(hooks);
        } else {
            policy.setHookAllowlist(hooks, false);
        }

        if (_listingsHash() != listings) aSwitchRewroteAListing = true;
    }

    function allowlistHook(
        uint256 hookSeed
    ) public {
        bytes32 listings = _listingsHash();

        policy.setHookAllowlist(_pickHook(hookSeed), true);

        if (_listingsHash() != listings) aSwitchRewroteAListing = true;
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    /// @dev Tier, decimals and feed are written back as they stand, so only `enabled` moves.
    function _setEnabled(
        Currency currency,
        bool enabled
    ) internal {
        (, ICollateralPolicy.Tier tier, uint8 decimals, address priceFeed) = policy.tokenConfig(currency);
        policy.setTokenConfig(currency, enabled, tier, decimals, priceFeed);
    }

    function _listingsHash() internal view returns (bytes32 hash) {
        for (uint256 i; i < keys.length; ++i) {
            hash = keccak256(abi.encode(hash, policy.listingOf(keys[i].toId())));
        }
    }

    function _pickToken(
        uint256 seed
    ) internal pure returns (Currency) {
        return Currency.wrap(seed % 2 == 0 ? RobinhoodChain.WETH : RobinhoodChain.USDG);
    }

    /// @dev `HOOK_ETH_USDG_DYN` is swap-only and passes the bit check; `HOOK_DOPPLER` touches
    ///      removals and is admitted by the allowlist alone (§6.1).
    function _pickHook(
        uint256 seed
    ) internal pure returns (address) {
        uint256 choice = seed % 3;
        if (choice == 0) return address(0);
        return choice == 1 ? Fixtures.HOOK_ETH_USDG_DYN : Fixtures.HOOK_DOPPLER;
    }
}

/// @notice What `borrow` is told about a pool, against what a deposit is told, in every state
///         the switches can reach (ARCHITECTURE §6.5, FAR-74).
contract CollateralPolicyOpenPoolsInvariantTest is Test {
    CollateralPolicy internal policy;
    OpenPoolsHandler internal handler;

    function setUp() public {
        policy = new CollateralPolicy(Currency.wrap(RobinhoodChain.USDG), address(this));
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.USDG), true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(1));
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.WETH), true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(1)
        );

        handler = new OpenPoolsHandler(policy);
        policy.setGuardian(handler.GUARDIAN());
        policy.transferOwnership(address(handler));
        vm.prank(address(handler));
        policy.acceptOwnership();

        // One pool per kind of hook. Nothing can be listed while a token is disabled, so a run
        // that disables first would otherwise never hold a pool that a revoke can close.
        handler.allowlistHook(2);
        for (uint256 hookSeed; hookSeed < 3; ++hookSeed) {
            handler.listPool(hookSeed);
        }

        targetContract(address(handler));
    }

    /// @notice A pool is open to `borrow` exactly when it is open to a deposit.
    /// @dev `borrow` asks `acceptsNewPositions`, a deposit asks `checkPool`. If the first could
    ///      answer true where the second reverts, a disabled token or a revoked hook would
    ///      still back new loans against collateral already held. The other direction is held
    ///      too: a pool the gate admits must not be closed to its borrowers.
    function invariant_aPoolIsOpenToBorrowingExactlyWhenItsGateAdmitsIt() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; ++i) {
            PoolKey memory key = _key(i);

            if (policy.acceptsNewPositions(key.toId())) {
                assertTrue(_gateAdmits(key), "a pool is open to borrowing while its gate refuses it");
            } else {
                assertFalse(_gateAdmits(key), "a pool the gate admits is closed to borrowing");
            }
        }
    }

    /// @notice Switching a token or a hook writes no listing (§6.5, Delisting).
    /// @dev Loans that exist are judged by the listing. A switch that moved a threshold, a cap
    ///      or the freeze flag would be deciding more than whether new risk may enter.
    function invariant_tokenAndHookSwitchesLeaveEveryListingAsItWas() public view {
        assertFalse(handler.aSwitchRewroteAListing(), "a token or hook switch changed a listing");
    }

    /// @dev Asked as a market of the pool's own tier would ask, so the tier rule is not what
    ///      is measured.
    function _gateAdmits(
        PoolKey memory key
    ) internal view returns (bool) {
        try policy.checkPool(key, policy.listingOf(key.toId()).tier) {
            return true;
        } catch {
            return false;
        }
    }

    function _key(
        uint256 i
    ) internal view returns (PoolKey memory) {
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) = handler.keys(i);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
    }
}
