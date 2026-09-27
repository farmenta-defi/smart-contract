// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Permit2Forwarder} from "@uniswap/v4-periphery/src/base/Permit2Forwarder.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {DebtMath} from "./DebtMath.sol";
import {MarketDebt} from "./MarketDebt.sol";
import {MarketLedger} from "./MarketLedger.sol";

/// @title MarketMint
/// @notice Linked mint-and-custody execution for `FarmentaMarket`.
/// @dev Runs by delegatecall and records collateral in the calling market's ERC-7201 layout.
library MarketMint {
    event CollateralDeposited(uint256 indexed tokenId, address indexed owner, PoolId indexed poolId);
    event LiquidityChanged(uint256 indexed tokenId, PoolId indexed poolId, int256 liqDelta);
    event CollectFees(uint256 indexed tokenId, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error NotTheDepositor(uint256 tokenId, address depositor);
    error ZeroLiquidity();
    error PositionAlreadyHeld(uint256 tokenId);
    error PositionIsEmpty(uint256 tokenId);
    error PositionBelowMinimum(uint256 principalUsd, uint256 minimumUsd);
    error NativeValueMismatch(uint256 expected, uint256 sent);
    error PermitDoesNotMatchPool();

    struct Env {
        IPositionManager positionManager;
        ICollateralPolicy policy;
        IPositionValuer valuer;
        MarketDebt.Env debt;
    }

    struct Params {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        bytes hookData;
    }

    /// @dev `FarmentaMarket.increaseLiquidity`'s arguments. Carried as one calldata struct so the
    ///      unoptimised `lite` build does not run out of stack slots.
    struct IncreaseParams {
        uint256 tokenId;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mintAndDeposit(
        Env calldata env,
        Params calldata p,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external returns (uint256 tokenId) {
        MarketDebt.accrue(env.debt);

        ISignatureTransfer.SignatureTransferDetails[] memory transfers = _transfersFor(
            p.poolKey,
            p.amount0Max,
            p.amount1Max,
            permit,
            _firstLeg(p.poolKey, p.amount0Max),
            address(env.positionManager)
        );
        // Read Permit2 from PositionManager rather than configuration, so the two addresses
        // cannot drift apart.
        IPermit2 permit2 = IPermit2(address(Permit2Forwarder(address(env.positionManager)).permit2()));
        permit2.permitTransferFrom(permit, transfers, msg.sender, signature);

        // `modifyLiquidities` returns no id. PositionManager assigns `nextTokenId`, then
        // increments it while locked, so reading before minting identifies this position.
        tokenId = env.positionManager.nextTokenId();
        env.positionManager.modifyLiquidities{value: msg.value}(
            _mintActions(p, address(env.debt.asset)), permit.deadline
        );
        _acceptCollateral(env, msg.sender, tokenId);
    }

    /// @dev Adds liquidity to a recorded position, having first claimed the fees it holds. The
    ///      caller's tokens go straight from Permit2 to PositionManager, which settles out of that
    ///      balance and sweeps the rest back, so nothing passes through the market while the pool's
    ///      hook runs. See `FarmentaMarket.increaseLiquidity`.
    ///
    ///      The claim is reported as `collectFees` reports one (FAR-52): `CollectFees` with the fees
    ///      read from fee growth before PositionManager is called, emitted there, and
    ///      `LiquidityChanged` once the addition has passed its health check. The fees
    ///      and the change `SWEEP` returns reach the caller together, so no balance change could
    ///      have told them apart.
    function increaseLiquidity(
        Env calldata env,
        IncreaseParams calldata p,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external {
        // A zero addition would be a fee claim with no recipient argument: `collectFees` is that
        // function (FAR-7). It would also run the pool's remove hook.
        if (p.liquidity == 0) revert ZeroLiquidity();
        MarketDebt.accrue(env.debt);

        (PoolKey memory key, PoolId poolId) = _admitIncrease(env, p.tokenId);
        // Emitted ahead of the claim it reports, which a revert anywhere below undoes with it. Held
        // until after the action instead, the two fees would not fit the unoptimised `lite` build's
        // stack.
        {
            (uint256 fees0, uint256 fees1) = env.valuer.feesOf(p.tokenId);
            emit CollectFees(p.tokenId, poolId, fees0, fees1);
        }
        ISignatureTransfer.SignatureTransferDetails[] memory transfers = _transfersFor(
            key, p.amount0Max, p.amount1Max, permit, _firstLeg(key, p.amount0Max), address(env.positionManager)
        );
        IPermit2 permit2 = IPermit2(address(Permit2Forwarder(address(env.positionManager)).permit2()));

        permit2.permitTransferFrom(permit, transfers, msg.sender, signature);
        env.positionManager.modifyLiquidities{value: msg.value}(
            _increaseActions(key, p, address(env.debt.asset)), permit.deadline
        );

        // The claim is what can lower the health factor, so it is checked after the whole action
        // (§7, as `collectFees` does in v0.40). A position owing nothing skips both this and the
        // §5.2 price gates it runs.
        MarketDebt.requireHealthy(env.debt, p.tokenId);
        emit LiquidityChanged(p.tokenId, poolId, int256(uint256(p.liquidity)));
    }

    /// @dev Only the depositor adds to a position, and only while its pool still passes §6.1.
    ///      Checked before any token moves: a pool frozen, or refused on a token or hook, since
    ///      the position was deposited takes no new capital (§6.5). Only pool-level rules can
    ///      have changed, and the position's value only grows, so the minimum needs no second look.
    function _admitIncrease(
        Env calldata env,
        uint256 tokenId
    ) private returns (PoolKey memory key, PoolId poolId) {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        MarketLedger.Loan storage loan = $.loans[tokenId];
        if (loan.owner != msg.sender) revert NotTheDepositor(tokenId, loan.owner);

        (key,) = env.positionManager.getPoolAndPositionInfo(tokenId);
        env.policy.checkPool(key, $.tier);
        // §5.3: every market transaction touching a meme pool but `liquidate` records an
        // observation first, which is also what the health check below prices the position
        // through. Placed after the checks above so a refusal names its own reason rather than
        // `TwapUnavailable`.
        if ($.tier == ICollateralPolicy.Tier.MEME) env.debt.oracle.record(key);
        poolId = loan.poolKeyId;
    }

    /// @dev Runs every §6.1 admission rule and records collateral after the market owns it.
    ///      The pool-level rules live in `CollateralPolicy.checkPool`; position-specific
    ///      liquidity and minimum checks stay here because policy has no valuer dependency.
    ///      The minimum is principal-only: fees can be collected immediately after intake.
    function acceptCollateral(
        Env calldata env,
        address depositor,
        uint256 tokenId
    ) external {
        _acceptCollateral(env, depositor, tokenId);
    }

    function _acceptCollateral(
        Env calldata env,
        address depositor,
        uint256 tokenId
    ) private {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        // Unreachable for ordinary intake: a recorded token is already held, and a mint creates
        // a new id. Keep the guard because a loan record must never be silently overwritten.
        if ($.loans[tokenId].owner != address(0)) revert PositionAlreadyHeld(tokenId);

        // Every intake path already holds the NFT. PositionManager clears info when burning, so
        // ownership implies existence; a nonexistent id yields an unlistable zeroed key.
        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(tokenId);
        ICollateralPolicy.Terms memory terms = env.policy.checkPool(key, $.tier);
        IPositionValuer.Valuation memory valuation = env.valuer.value(tokenId);
        if (valuation.liquidity == 0) revert PositionIsEmpty(tokenId);

        // Apply the §6.3 removal haircut before checking the minimum: an
        // immediately withdrawable position cannot satisfy the floor only before its haircut.
        uint256 recoverableUsd = DebtMath.recoverablePrincipal(valuation.principalUsd, terms.removeHaircutBps);
        if (recoverableUsd < terms.minPositionUsd) {
            revert PositionBelowMinimum(recoverableUsd, terms.minPositionUsd);
        }

        PoolId poolId = key.toId();
        $.loans[tokenId] = MarketLedger.Loan({owner: depositor, debtShares: 0, poolKeyId: poolId, tier: $.tier});
        emit CollateralDeposited(tokenId, depositor, poolId);
    }

    /// @dev ETH can only be currency0 because `address(0)` sorts first. It arrives as
    ///      `msg.value`, so a native pool has one ERC-20 leg and an ERC-20 pair has two, and the
    ///      value sent must be the ETH maximum for a native pool and nothing otherwise.
    function _firstLeg(
        PoolKey memory key,
        uint128 amount0Max
    ) private view returns (uint256 firstLeg) {
        firstLeg = key.currency0.isAddressZero() ? 1 : 0;
        uint256 expectedValue = firstLeg == 1 ? amount0Max : 0;
        if (msg.value != expectedValue) revert NativeValueMismatch(expectedValue, msg.value);
    }

    /// @dev Each ERC-20 leg of `key`, in pool order, pulled at its maximum and delivered to `to`.
    ///      The permit must list exactly those currencies in that order.
    function _transfersFor(
        PoolKey memory key,
        uint128 amount0Max,
        uint128 amount1Max,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        uint256 firstLeg,
        address to
    ) private pure returns (ISignatureTransfer.SignatureTransferDetails[] memory transfers) {
        uint256 count = 2 - firstLeg;
        if (permit.permitted.length != count) revert PermitDoesNotMatchPool();

        transfers = new ISignatureTransfer.SignatureTransferDetails[](count);
        for (uint256 i = firstLeg; i < 2; ++i) {
            (Currency currency, uint128 amountMax) = (key.currency1, amount1Max);
            if (i == 0) (currency, amountMax) = (key.currency0, amount0Max);
            if (permit.permitted[i - firstLeg].token != Currency.unwrap(currency)) revert PermitDoesNotMatchPool();
            transfers[i - firstLeg] = ISignatureTransfer.SignatureTransferDetails({to: to, requestedAmount: amountMax});
        }
    }

    /// @dev PositionManager pays each leg's debt out of its own balance (`payerIsUser = false`),
    ///      which is what Permit2 just delivered plus `msg.value`, then sweeps whatever is left of
    ///      each currency back to the caller. The market is never a payer and holds none of the
    ///      caller's tokens while the pool's hook runs, so the share price a hook can redeem at
    ///      is the one everyone else sees (FAR-45). The borrow asset is swept first (§4.1 v0.26),
    ///      as in `_increaseActions`.
    function _mintActions(
        Params calldata p,
        address asset
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        (Currency first, Currency second) = Currency.unwrap(p.poolKey.currency1) == asset
            ? (p.poolKey.currency1, p.poolKey.currency0)
            : (p.poolKey.currency0, p.poolKey.currency1);
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(
            p.poolKey, p.tickLower, p.tickUpper, p.liquidity, p.amount0Max, p.amount1Max, address(this), p.hookData
        );
        params[1] = abi.encode(p.poolKey.currency0, ActionConstants.OPEN_DELTA, false);
        params[2] = abi.encode(p.poolKey.currency1, ActionConstants.OPEN_DELTA, false);
        params[3] = abi.encode(first, msg.sender);
        params[4] = abi.encode(second, msg.sender);
        return abi.encode(actions, params);
    }

    /// @dev The fees come out first, then the liquidity goes in. `INCREASE_LIQUIDITY` credits the
    ///      position's whole uncollected fee balance against its cost, and `SETTLE` reverts
    ///      (`DeltaNotNegative`) on a leg where that credit exceeds the cost — which is every
    ///      addition to an out-of-range position holding fees on the leg it no longer spends. So the
    ///      claim is made first, as its own `DECREASE_LIQUIDITY(0)` plus a `TAKE` per leg, and the
    ///      addition that follows can only owe (v0.47, decided on PR #19).
    ///
    ///      PositionManager pays each leg's full debt out of its own balance (`payerIsUser =
    ///      false`), which is what Permit2 just delivered plus `msg.value`, then sweeps whatever is
    ///      left of each currency back to the caller.
    ///
    ///      **The borrow asset is taken and swept first** (§4.1 v0.26, as `collectFees` does in
    ///      v0.40). In a
    ///      native-ETH pool the ETH is `currency0`, and sending it runs the caller's code; the USDG
    ///      change has left by then. None of the market's own cash is on this path either way; the
    ///      order is kept so that no function is an exception to the rule.
    function _increaseActions(
        PoolKey memory key,
        IncreaseParams calldata p,
        address asset
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE),
            uint8(Actions.TAKE),
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        (Currency first, Currency second) =
            Currency.unwrap(key.currency1) == asset ? (key.currency1, key.currency0) : (key.currency0, key.currency1);
        bytes[] memory params = new bytes[](8);
        // A `DECREASE_LIQUIDITY` of zero realises the whole fee balance and no principal, the same
        // claim `collectFees` makes (FAR-7).
        params[0] = abi.encode(p.tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(first, msg.sender, uint256(ActionConstants.OPEN_DELTA));
        params[2] = abi.encode(second, msg.sender, uint256(ActionConstants.OPEN_DELTA));
        params[3] = abi.encode(p.tokenId, uint256(p.liquidity), p.amount0Max, p.amount1Max, bytes(""));
        params[4] = abi.encode(key.currency0, ActionConstants.OPEN_DELTA, false);
        params[5] = abi.encode(key.currency1, ActionConstants.OPEN_DELTA, false);
        params[6] = abi.encode(first, msg.sender);
        params[7] = abi.encode(second, msg.sender);
        return abi.encode(actions, params);
    }
}
