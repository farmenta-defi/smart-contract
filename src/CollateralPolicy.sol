// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {HookPermissions} from "./libraries/HookPermissions.sol";
import {TierPresets} from "./libraries/TierPresets.sol";

/// @title CollateralPolicy
/// @notice Decides which pools may back a loan and on what terms (ARCHITECTURE §4.5, §6).
/// @dev A rules engine with no external dependencies: it reads no position, calls no oracle,
///      holds no funds. §6.1 writes the gate as `isAcceptable(tokenId)`, which would make the
///      policy read a position the valuer has already read. It is split instead —
///      `checkPool` enforces everything knowable from the `PoolKey`, and the value-dependent
///      rules travel back in `Terms` for the market to apply once it has valued the position.
///      Every §6.1 condition is still enforced, just not twice.
///
///      Since v0.5 nothing is accepted automatically. Every pool is listed by the owner after
///      the off-chain review in §6.3, and every mutating function here is `onlyOwner` —
///      there is no permissionless path into the configuration.
contract CollateralPolicy is ICollateralPolicy, Ownable2Step {
    /// @param enabled Whether the token may appear in collateral at all.
    /// @param tier Risk class; a pool inherits the riskier of its two tokens.
    /// @param decimals Recorded at listing (§6.3), never read live — a token that could
    ///        change its reported decimals could change every position's value.
    struct TokenConfig {
        bool enabled;
        Tier tier;
        uint8 decimals;
    }

    /// @notice Terms the owner writes when listing; validated against the tier preset.
    struct ListingParams {
        uint16 maxLtvBps;
        uint16 ltBps;
        uint16 liquidatorBonusBps;
        uint16 removeHaircutBps;
        uint128 debtCapUsdg;
        uint128 minPositionUsd;
    }

    /// @dev `ltStartBps` and `ltTargetBps` bracket the ramp; with no ramp they are equal.
    struct Listing {
        bool listed;
        bool frozen;
        Tier tier;
        uint16 maxLtvBps;
        uint16 ltStartBps;
        uint16 ltTargetBps;
        uint40 rampStart;
        uint40 rampDuration;
        uint16 liquidatorBonusBps;
        uint16 removeHaircutBps;
        uint128 debtCapUsdg;
        uint128 minPositionUsd;
    }

    uint16 internal constant BPS = 10_000;

    /// @notice The only borrow asset in the MVP; every accepted pair must quote in it (§1).
    Currency public immutable quote;

    mapping(Currency currency => TokenConfig) public tokenConfig;

    /// @notice Hooks cleared by review despite touching remove-liquidity (§6.1 manual path).
    mapping(address hooks => bool) public hookAllowlist;

    mapping(PoolId poolId => Listing) internal _listings;

    event TokenConfigured(Currency indexed currency, bool enabled, Tier tier, uint8 decimals);
    event HookAllowlisted(address indexed hooks, bool allowed);
    event PoolListed(PoolId indexed poolId, Tier tier, ListingParams params);
    event PoolTermsUpdated(PoolId indexed poolId, ListingParams params);
    event PoolFrozen(PoolId indexed poolId, bool frozen);
    event LtRampScheduled(PoolId indexed poolId, uint16 ltFromBps, uint16 ltTargetBps, uint40 start, uint40 duration);

    error TokenNotEnabled(Currency currency);
    error PairMustQuoteInUsdg();
    error HookNotPermitted(address hooks);
    error PoolAlreadyListed(PoolId poolId);
    error PoolNotListed(PoolId poolId);
    error PoolFrozenForNewPositions(PoolId poolId);
    error WrongTier(Tier poolTier, Tier marketTier);
    error LooserThanPreset(string parameter);
    error NoBorrowingRoom(uint16 maxLtvBps, uint16 ltBps);
    error HaircutTooLarge(uint16 removeHaircutBps);
    error RampStartInThePast();
    error RampDurationIsZero();
    error RampBelowMaxLtvRequiresFreeze(uint16 maxLtvBps, uint16 ltTargetBps);
    error UnfreezeWouldLeaveNoBorrowingRoom(uint16 maxLtvBps, uint16 ltBps);

    constructor(
        Currency quote_,
        address owner_
    ) Ownable(owner_) {
        quote = quote_;
    }

    /* ------------------------------ configuration ----------------------------- */

    /// @dev Disabling a token does not unlist pools that contain it. Unwinding a token is a
    ///      per-pool decision — freeze and ramp them (§6.5) — because a blanket switch would
    ///      strand collateral in pools nobody had reviewed for removal.
    function setTokenConfig(
        Currency currency,
        bool enabled,
        Tier tier,
        uint8 decimals
    ) external onlyOwner {
        tokenConfig[currency] = TokenConfig({enabled: enabled, tier: tier, decimals: decimals});
        emit TokenConfigured(currency, enabled, tier, decimals);
    }

    function setHookAllowlist(
        address hooks,
        bool allowed
    ) external onlyOwner {
        hookAllowlist[hooks] = allowed;
        emit HookAllowlisted(hooks, allowed);
    }

    /* --------------------------------- listing -------------------------------- */

    /// @notice Lists a pool as acceptable collateral, on the given terms.
    /// @dev The tier is derived from the pool's tokens rather than chosen by the caller, so a
    ///      meme pair cannot be listed on blue-chip terms by mistake.
    function list(
        PoolKey calldata key,
        ListingParams calldata params
    ) external onlyOwner {
        PoolId poolId = key.toId();
        if (_listings[poolId].listed) revert PoolAlreadyListed(poolId);

        Tier tier = _poolTier(key);
        _requireHookPermitted(address(key.hooks));
        _validate(tier, params, true); // a pool is never listed already frozen

        _listings[poolId] = Listing({
            listed: true,
            frozen: false,
            tier: tier,
            maxLtvBps: params.maxLtvBps,
            ltStartBps: params.ltBps,
            ltTargetBps: params.ltBps,
            rampStart: 0,
            rampDuration: 0,
            liquidatorBonusBps: params.liquidatorBonusBps,
            removeHaircutBps: params.removeHaircutBps,
            debtCapUsdg: params.debtCapUsdg,
            minPositionUsd: params.minPositionUsd
        });

        emit PoolListed(poolId, tier, params);
    }

    /// @notice Rewrites a listed pool's terms.
    /// @dev Takes effect immediately for loans that already exist (§6.5). Lowering LT can
    ///      therefore make a healthy loan liquidatable, and the borrower pays the liquidator's
    ///      bonus without having done anything wrong. That is a deliberate trade for being
    ///      able to react to a pool going bad; §15 records it next to the upgrade key.
    ///      Any active ramp is cleared — the new terms are the schedule now.
    ///
    ///      While the pool is frozen the threshold may be written at or below max LTV. That
    ///      is the instant equivalent of a ramp: no new borrows can be taken, so nothing is
    ///      handed out underwater, and tightening stays as fast as the decision to allow no
    ///      rate limit intended.
    function updateTerms(
        PoolId poolId,
        ListingParams calldata params
    ) external onlyOwner {
        Listing storage listing = _listings[poolId];
        if (!listing.listed) revert PoolNotListed(poolId);

        _validate(listing.tier, params, !listing.frozen);

        listing.maxLtvBps = params.maxLtvBps;
        listing.ltStartBps = params.ltBps;
        listing.ltTargetBps = params.ltBps;
        listing.rampStart = 0;
        listing.rampDuration = 0;
        listing.liquidatorBonusBps = params.liquidatorBonusBps;
        listing.removeHaircutBps = params.removeHaircutBps;
        listing.debtCapUsdg = params.debtCapUsdg;
        listing.minPositionUsd = params.minPositionUsd;

        emit PoolTermsUpdated(poolId, params);
    }

    /// @notice Stops new collateral and new borrowing for a pool, or resumes them.
    /// @dev Freezing leaves existing loans entirely alone: interest accrues, and repay,
    ///      collectFees, decreaseLiquidity, withdrawCollateral and liquidate all keep
    ///      working. Trapping collateral or switching off liquidation would manufacture the
    ///      bad debt freezing is meant to avoid.
    function setFrozen(
        PoolId poolId,
        bool frozen
    ) external onlyOwner {
        Listing storage listing = _listings[poolId];
        if (!listing.listed) revert PoolNotListed(poolId);
        // Unfreezing is judged on where the threshold is *heading*, not where it stands.
        // A ramp that has not started yet still reads as its starting value, so checking the
        // current threshold would let a pool be reopened moments before it ramps below max
        // LTV — and every loan taken in that window is liquidatable as soon as the ramp
        // lands. The effective threshold never falls below the target, so testing the target
        // covers both the ramping and the settled case.
        if (!frozen && listing.maxLtvBps >= listing.ltTargetBps) {
            revert UnfreezeWouldLeaveNoBorrowingRoom(listing.maxLtvBps, listing.ltTargetBps);
        }

        listing.frozen = frozen;
        emit PoolFrozen(poolId, frozen);
    }

    /// @notice Schedules a gradual fall in a pool's liquidation threshold.
    /// @dev How Farmenta leaves a pool it no longer wants exposure to: positions are pushed
    ///      into liquidation over a published window instead of all at once. The schedule
    ///      lives on-chain precisely so a borrower can read when their position is due to
    ///      fall — with no rate limit on tightening, legibility is the only protection they
    ///      have.
    ///
    ///      The ramp starts from the **current** effective threshold, so scheduling a second
    ///      ramp can never walk the threshold back up.
    ///
    ///      The threshold may be driven below max LTV — emptying a pool is the point — but
    ///      only once the pool is frozen. The invariant that survives is narrower than
    ///      "borrowing room always exists": while a pool still accepts new positions, it has
    ///      room. `setFrozen` enforces the other half by refusing to unfreeze into a pool
    ///      that has already ramped past it.
    function scheduleLtRamp(
        PoolId poolId,
        uint16 ltTargetBps,
        uint40 rampStart,
        uint40 rampDuration
    ) external onlyOwner {
        Listing storage listing = _listings[poolId];
        if (!listing.listed) revert PoolNotListed(poolId);
        // Timestamp comparison is inherent here, not incidental: the ramp is a published
        // schedule and §5.3/§7 define every time-based rule on block.timestamp. On this
        // Orbit chain block.number reports the L1 block and is useless for timing, and a
        // sequencer nudging the clock by seconds cannot meaningfully move a ramp measured
        // in days.
        // forge-lint: disable-next-line(block-timestamp)
        if (rampStart < block.timestamp) revert RampStartInThePast();
        if (rampDuration == 0) revert RampDurationIsZero();

        uint16 ltNow = _effectiveLt(listing);
        if (ltTargetBps > ltNow) revert LooserThanPreset("ltTarget");

        // A ramp is allowed to drive the threshold below max LTV — that is exactly how a
        // pool is emptied. It just may not do so while the pool still takes new positions,
        // or borrowers would be handed loans that are already underwater.
        if (ltTargetBps <= listing.maxLtvBps && !listing.frozen) {
            revert RampBelowMaxLtvRequiresFreeze(listing.maxLtvBps, ltTargetBps);
        }

        listing.ltStartBps = ltNow;
        listing.ltTargetBps = ltTargetBps;
        listing.rampStart = rampStart;
        listing.rampDuration = rampDuration;

        emit LtRampScheduled(poolId, ltNow, ltTargetBps, rampStart, rampDuration);
    }

    /* ---------------------------------- views --------------------------------- */

    /// @inheritdoc ICollateralPolicy
    function termsOf(
        PoolId poolId
    ) public view returns (Terms memory) {
        Listing storage listing = _listings[poolId];
        if (!listing.listed) revert PoolNotListed(poolId);

        return Terms({
            maxLtvBps: listing.maxLtvBps,
            ltBps: _effectiveLt(listing),
            liquidatorBonusBps: listing.liquidatorBonusBps,
            removeHaircutBps: listing.removeHaircutBps,
            debtCapUsdg: listing.debtCapUsdg,
            minPositionUsd: listing.minPositionUsd,
            tier: listing.tier
        });
    }

    /// @inheritdoc ICollateralPolicy
    function acceptsNewPositions(
        PoolId poolId
    ) external view returns (bool) {
        Listing storage listing = _listings[poolId];
        return listing.listed && !listing.frozen;
    }

    /// @notice Everything §6.1 can decide from the pool alone, for a market of `marketTier`.
    /// @dev Reverts with the specific reason rather than returning false, so a rejected
    ///      deposit tells the user which rule stopped it. The caller still has to enforce the
    ///      value-dependent rules from the returned terms: `minPositionUsd` and the debt cap.
    function checkPool(
        PoolKey calldata key,
        Tier marketTier
    ) external view returns (Terms memory) {
        PoolId poolId = key.toId();
        Listing storage listing = _listings[poolId];

        if (!listing.listed) revert PoolNotListed(poolId);
        if (listing.frozen) revert PoolFrozenForNewPositions(poolId);
        if (listing.tier != marketTier) revert WrongTier(listing.tier, marketTier);

        // Re-checked at deposit time, not just at listing: a token can be disabled after a
        // pool was listed, and the hook allowlist can be revoked.
        _requireEnabled(key.currency0);
        _requireEnabled(key.currency1);
        _requireQuoted(key);
        _requireHookPermitted(address(key.hooks));

        return termsOf(poolId);
    }

    /// @notice Raw listing record, for the indexer and the frontend.
    function listingOf(
        PoolId poolId
    ) external view returns (Listing memory) {
        return _listings[poolId];
    }

    /// @notice Liquidation threshold in force right now, resolved through any ramp.
    function effectiveLt(
        PoolId poolId
    ) external view returns (uint16) {
        Listing storage listing = _listings[poolId];
        if (!listing.listed) revert PoolNotListed(poolId);
        return _effectiveLt(listing);
    }

    /* -------------------------------- internals ------------------------------- */

    /// @dev Linear between `rampStart` and `rampStart + rampDuration`; flat outside it.
    function _effectiveLt(
        Listing storage listing
    ) internal view returns (uint16) {
        uint40 start = listing.rampStart;
        uint40 duration = listing.rampDuration;
        if (duration == 0 || block.timestamp <= start) return listing.ltStartBps;

        uint256 elapsed = block.timestamp - start;
        if (elapsed >= duration) return listing.ltTargetBps;

        uint256 fall = uint256(listing.ltStartBps - listing.ltTargetBps);
        // Safe: the subtrahend never exceeds `fall`, so the result stays within [ltTarget,
        // ltStart] and both of those are uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(listing.ltStartBps - (fall * elapsed) / duration);
    }

    /// @dev A pool inherits the riskier of its two tokens (§6.1). `Tier.NONE` sorts below
    ///      both, so a pool holding an unconfigured token is caught by `_requireEnabled`
    ///      rather than slipping through as blue-chip.
    function _poolTier(
        PoolKey calldata key
    ) internal view returns (Tier) {
        _requireEnabled(key.currency0);
        _requireEnabled(key.currency1);
        _requireQuoted(key);

        Tier t0 = tokenConfig[key.currency0].tier;
        Tier t1 = tokenConfig[key.currency1].tier;
        return t0 > t1 ? t0 : t1;
    }

    function _requireEnabled(
        Currency currency
    ) internal view {
        if (!tokenConfig[currency].enabled) revert TokenNotEnabled(currency);
    }

    function _requireQuoted(
        PoolKey calldata key
    ) internal view {
        // Currency defines `==` but not `!=`, so the negation is spelled out.
        if (!(key.currency0 == quote) && !(key.currency1 == quote)) revert PairMustQuoteInUsdg();
    }

    function _requireHookPermitted(
        address hooks
    ) internal view {
        if (HookPermissions.leavesRemoveLiquidityAlone(IHooks(hooks))) return;
        if (!hookAllowlist[hooks]) revert HookNotPermitted(hooks);
    }

    /// @dev Deviations from the tier preset are accepted only toward stricter, and the
    ///      direction differs per parameter — see TierPresets.
    /// @param requireBorrowingRoom False only when the pool is frozen. A frozen pool takes
    ///        no new borrows, so a threshold at or under max LTV harms nobody — and refusing
    ///        it would block the fastest way to tighten a pool that has just gone bad, which
    ///        the "no rate limit, no floor" decision exists to keep available.
    function _validate(
        Tier tier,
        ListingParams calldata params,
        bool requireBorrowingRoom
    ) internal pure {
        TierPresets.Preset memory preset = TierPresets.forTier(tier);

        if (params.maxLtvBps > preset.maxLtvBps) revert LooserThanPreset("maxLtv");
        if (params.ltBps > preset.ltBps) revert LooserThanPreset("lt");
        if (params.liquidatorBonusBps < preset.minLiquidatorBonusBps) revert LooserThanPreset("liquidatorBonus");
        if (params.debtCapUsdg > preset.maxDebtCapUsdg) revert LooserThanPreset("debtCap");
        if (params.minPositionUsd < preset.minPositionUsd) revert LooserThanPreset("minPosition");

        if (requireBorrowingRoom && (params.maxLtvBps == 0 || params.maxLtvBps >= params.ltBps)) {
            revert NoBorrowingRoom(params.maxLtvBps, params.ltBps);
        }
        if (params.removeHaircutBps > BPS) revert HaircutTooLarge(params.removeHaircutBps);
    }
}
