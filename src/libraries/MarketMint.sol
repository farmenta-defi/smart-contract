// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Permit2Forwarder} from "@uniswap/v4-periphery/src/base/Permit2Forwarder.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {MarketDebt} from "./MarketDebt.sol";
import {MarketLedger} from "./MarketLedger.sol";

/// @title MarketMint
/// @notice Linked mint-and-custody execution for `FarmentaMarket`.
/// @dev Runs by delegatecall and records collateral in the calling market's ERC-7201 layout.
library MarketMint {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    event CollateralDeposited(uint256 indexed tokenId, address indexed owner);

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

    function mintAndDeposit(
        Env calldata env,
        Params calldata p,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external returns (uint256 tokenId) {
        MarketDebt.accrue(env.debt);

        uint256 firstLeg = p.poolKey.currency0.isAddressZero() ? 1 : 0;
        uint256 expectedValue = firstLeg == 1 ? p.amount0Max : 0;
        if (msg.value != expectedValue) revert NativeValueMismatch(expectedValue, msg.value);

        ISignatureTransfer.SignatureTransferDetails[] memory transfers = _transfersFor(p, permit, firstLeg);
        IPermit2 permit2 = IPermit2(address(Permit2Forwarder(address(env.positionManager)).permit2()));

        uint256[2] memory held;
        for (uint256 i = firstLeg; i < 2; ++i) {
            (Currency currency,) = _leg(p, i);
            held[i] = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        }

        permit2.permitTransferFrom(permit, transfers, msg.sender, signature);
        for (uint256 i = firstLeg; i < 2; ++i) {
            (Currency currency, uint128 amountMax) = _leg(p, i);
            _allowPositionManager(env.positionManager, permit2, currency, amountMax);
        }

        tokenId = env.positionManager.nextTokenId();
        env.positionManager.modifyLiquidities{value: msg.value}(_mintActions(p), permit.deadline);
        _acceptCollateral(env, msg.sender, tokenId);

        for (uint256 i = firstLeg; i < 2; ++i) {
            (Currency currency,) = _leg(p, i);
            _returnChange(currency, held[i]);
        }
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
        if ($.loans[tokenId].owner != address(0)) revert PositionAlreadyHeld(tokenId);

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(tokenId);
        ICollateralPolicy.Terms memory terms = env.policy.checkPool(key, $.tier);
        IPositionValuer.Valuation memory valuation = env.valuer.value(tokenId);
        if (valuation.liquidity == 0) revert PositionIsEmpty(tokenId);

        uint256 recoverableUsd = valuation.principalUsd * (BPS - terms.removeHaircutBps) / BPS;
        if (recoverableUsd < terms.minPositionUsd) {
            revert PositionBelowMinimum(recoverableUsd, terms.minPositionUsd);
        }

        $.loans[tokenId] = MarketLedger.Loan({owner: depositor, debtShares: 0, poolKeyId: key.toId(), tier: $.tier});
        emit CollateralDeposited(tokenId, depositor);
    }

    function _leg(
        Params calldata p,
        uint256 i
    ) private pure returns (Currency currency, uint128 amountMax) {
        if (i == 0) return (p.poolKey.currency0, p.amount0Max);
        return (p.poolKey.currency1, p.amount1Max);
    }

    function _transfersFor(
        Params calldata p,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        uint256 firstLeg
    ) private view returns (ISignatureTransfer.SignatureTransferDetails[] memory transfers) {
        uint256 count = 2 - firstLeg;
        if (permit.permitted.length != count) revert PermitDoesNotMatchPool();

        transfers = new ISignatureTransfer.SignatureTransferDetails[](count);
        for (uint256 i = firstLeg; i < 2; ++i) {
            (Currency currency, uint128 amountMax) = _leg(p, i);
            if (permit.permitted[i - firstLeg].token != Currency.unwrap(currency)) revert PermitDoesNotMatchPool();
            transfers[i - firstLeg] =
                ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amountMax});
        }
    }

    function _allowPositionManager(
        IPositionManager positionManager,
        IPermit2 permit2,
        Currency currency,
        uint256 amount
    ) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), address(permit2)) < amount) {
            token.forceApprove(address(permit2), type(uint256).max);
        }

        (uint160 allowed, uint48 expiration,) =
            permit2.allowance(address(this), address(token), address(positionManager));
        if (allowed != type(uint160).max || expiration != type(uint48).max) {
            permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        }
    }

    function _mintActions(
        Params calldata p
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            p.poolKey, p.tickLower, p.tickUpper, p.liquidity, p.amount0Max, p.amount1Max, address(this), p.hookData
        );
        params[1] = abi.encode(p.poolKey.currency0, p.poolKey.currency1);
        params[2] = abi.encode(p.poolKey.currency0, msg.sender);
        params[3] = abi.encode(p.poolKey.currency1, msg.sender);
        return abi.encode(actions, params);
    }

    function _returnChange(
        Currency currency,
        uint256 held
    ) private {
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 change = token.balanceOf(address(this)) - held;
        if (change != 0) token.safeTransfer(msg.sender, change);
    }
}
