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

/// @notice Drives the policy through arbitrary owner actions, including time passing.
/// @dev The handler *is* the owner. The point is not to check that a stranger is blocked —
///      unit tests do that — but that even the owner, acting in any order, cannot reach a
///      state the design forbids.
///
///      Inputs are bounded into the plausible range rather than left fully random. Raw
///      uint16s almost never satisfy the tighten-only rules, so an unbounded campaign spends
///      itself bouncing off validation and reports green having barely listed a pool. The
///      rules themselves are covered by unit tests; what this campaign is for is the state
///      machine behind them.
contract PolicyHandler is Test {
    /// @dev Enough pools to exercise the registry, few enough that the invariants' per-pool
    ///      loop stays cheap.
    uint256 internal constant MAX_POOLS = 8;

    CollateralPolicy public policy;
    PoolKey[] public keys;

    constructor(
        CollateralPolicy policy_
    ) {
        policy = policy_;
    }

    function listPool(
        uint16 maxLtv,
        uint16 lt,
        uint16 bonus,
        uint128 cap,
        uint128 minPos
    ) public {
        if (keys.length >= MAX_POOLS) return;

        // The key is derived from the count, not from a fuzzed seed: seeds repeat often, and
        // every repeat is a PoolAlreadyListed revert instead of a step through the machine.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.WETH),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: uint24(keys.length + 1),
            tickSpacing: int24(uint24(keys.length + 1)),
            hooks: IHooks(address(0))
        });

        policy.list(key, _boundTerms(maxLtv, lt, bonus, cap, minPos));
        keys.push(key);
    }

    function updateTerms(
        uint256 idx,
        uint16 maxLtv,
        uint16 lt,
        uint16 bonus,
        uint128 cap,
        uint128 minPos
    ) public {
        policy.updateTerms(_pick(idx).toId(), _boundTerms(maxLtv, lt, bonus, cap, minPos));
    }

    function setFrozen(
        uint256 idx,
        bool frozen
    ) public {
        policy.setFrozen(_pick(idx).toId(), frozen);
    }

    /// @dev The target is bounded to the threshold in force, so the campaign exercises the
    ///      freeze rule rather than failing the "no looser than now" check over and over.
    function scheduleRamp(
        uint256 idx,
        uint16 target,
        uint40 delay,
        uint40 duration
    ) public {
        PoolId poolId = _pick(idx).toId();
        policy.scheduleLtRamp(
            poolId,
            uint16(bound(target, 0, policy.effectiveLt(poolId))),
            uint40(block.timestamp) + uint40(bound(delay, 1, 30 days)),
            uint40(bound(duration, 1, 180 days))
        );
    }

    /// @dev Time is the input the ramp exists to consume, so the campaign has to move it.
    function passTime(
        uint40 elapsed
    ) public {
        vm.warp(block.timestamp + bound(elapsed, 1, 90 days));
    }

    function keyCount() external view returns (uint256) {
        return keys.length;
    }

    /// @dev Blue-chip bounds from §6.2, with room on both sides so tightening and loosening
    ///      within the preset are both reachable. Raw uint16s almost never satisfy the
    ///      tighten-only rules, and an unbounded campaign reports green having barely listed
    ///      a pool; the rules themselves are covered by unit tests.
    function _boundTerms(
        uint16 maxLtv,
        uint16 lt,
        uint16 bonus,
        uint128 cap,
        uint128 minPos
    ) internal pure returns (CollateralPolicy.ListingParams memory) {
        uint16 boundedMaxLtv = uint16(bound(maxLtv, 100, 6400));
        return CollateralPolicy.ListingParams({
            maxLtvBps: boundedMaxLtv,
            ltBps: uint16(bound(lt, uint256(boundedMaxLtv) + 1, 7500)),
            liquidatorBonusBps: uint16(bound(bonus, 500, 5000)),
            removeHaircutBps: 0,
            debtCapUsdg: uint128(bound(cap, 0, 500_000e6)),
            minPositionUsd: uint128(bound(minPos, 50e18, 1_000_000e18))
        });
    }

    function _pick(
        uint256 idx
    ) internal view returns (PoolKey memory) {
        return keys[idx % keys.length];
    }
}

/// @notice The safety claims of the listing design, asserted against every reachable state.
/// @dev These are the properties the v0.5 model rests on. Unit tests check them at points I
///      thought to write down; this checks them after any sequence of owner calls and any
///      amount of elapsed time — which is how the borrowing-room rule was found to be wrong
///      in the first place.
contract CollateralPolicyInvariantTest is Test {
    CollateralPolicy internal policy;
    PolicyHandler internal handler;

    function setUp() public {
        policy = new CollateralPolicy(Currency.wrap(RobinhoodChain.USDG), address(this));
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.USDG), true, ICollateralPolicy.Tier.BLUE_CHIP, 6);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.WETH), true, ICollateralPolicy.Tier.BLUE_CHIP, 18);

        handler = new PolicyHandler(policy);
        policy.transferOwnership(address(handler));
        vm.prank(address(handler));
        policy.acceptOwnership();

        // Seed one pool so the actions that operate on an existing listing have something to
        // reach for. Without it the fuzzer spends its first calls bouncing off an empty
        // registry, and three of the five actions can never run at all.
        handler.listPool(6500, 7500, 500, 500_000e6, 50e18);

        targetContract(address(handler));
    }

    /// @notice A pool open for business always has room to borrow into.
    /// @dev The invariant that replaced "maxLTV < LT always", which is false during a ramp.
    ///      If this breaks, borrowers can be handed loans that are liquidatable on the block
    ///      they open.
    function invariant_openPoolsHaveBorrowingRoom() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; ++i) {
            PoolId poolId = _poolId(i);
            if (!policy.acceptsNewPositions(poolId)) continue;
            ICollateralPolicy.Terms memory terms = policy.termsOf(poolId);
            assertLt(terms.maxLtvBps, terms.ltBps, "an open pool has no borrowing room");
        }
    }

    /// @notice No sequence of owner calls can loosen a pool past its tier preset.
    /// @dev The core promise of the v0.5 model: the loosest terms Farmenta can offer are
    ///      readable from TierPresets, not dependent on how carefully a listing was filled
    ///      in. Checked on every parameter, since each tightens in its own direction.
    function invariant_termsNeverEscapeTheTierPreset() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; ++i) {
            ICollateralPolicy.Terms memory terms = policy.termsOf(_poolId(i));
            TierPresets.Preset memory preset = TierPresets.forTier(terms.tier);

            assertLe(terms.maxLtvBps, preset.maxLtvBps, "max LTV escaped its preset");
            assertLe(terms.ltBps, preset.ltBps, "liquidation threshold escaped its preset");
            assertGe(terms.liquidatorBonusBps, preset.minLiquidatorBonusBps, "bonus fell below its preset");
            assertLe(terms.debtCapUsdg, preset.maxDebtCapUsdg, "debt cap escaped its preset");
            assertGe(terms.minPositionUsd, preset.minPositionUsd, "minimum position fell below its preset");
        }
    }

    /// @notice A ramp never resolves outside the bracket it was scheduled with.
    /// @dev A borrower reads the schedule to know when their position falls. If the
    ///      interpolation could overshoot the target or exceed the start, that reading would
    ///      be wrong in the one direction that costs them money.
    function invariant_rampStaysWithinItsBracket() public view {
        uint256 n = handler.keyCount();
        for (uint256 i; i < n; ++i) {
            PoolId poolId = _poolId(i);
            CollateralPolicy.Listing memory listing = policy.listingOf(poolId);
            uint16 ltNow = policy.effectiveLt(poolId);

            assertLe(ltNow, listing.ltStartBps, "threshold rose above where the ramp began");
            assertGe(ltNow, listing.ltTargetBps, "threshold fell past where the ramp was aimed");
        }
    }

    function _poolId(
        uint256 i
    ) internal view returns (PoolId) {
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) = handler.keys(i);
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks}).toId();
    }
}
