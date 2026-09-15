// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {MarketDebt} from "./MarketDebt.sol";
import {MarketLedger} from "./MarketLedger.sol";

/// @title MarketLiquidity
/// @notice Linked execution for what a borrower does to a position the market holds: claiming
///         its fees (FAR-7), with decreasing and increasing its liquidity (FAR-8, FAR-9) to come.
/// @dev Runs by delegatecall, like `MarketDebt` and `MarketMint`. `address(this)` is the market,
///      which owns the NFT and is therefore the only caller PositionManager lets decrease it;
///      `msg.sender` is still the borrower. The market keeps the wrapper, the pause and the guard
///      (§4.1 v0.33).
library MarketLiquidity {
    /// @notice A position's fees were claimed to `to` (§4.1, `poolId` per v0.30).
    /// @dev `amount0`/`amount1` are `to`'s balance change across the claim, not a figure the
    ///      ledger reads. A contract `to` that moves the ETH on as it arrives can misstate its own
    ///      receipt, the same caveat `Liquidate` carries.
    event CollectFees(uint256 indexed tokenId, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    error NotTheDepositor(uint256 tokenId, address depositor);
    error InvalidRecipient(address to);

    /// @notice The market's dependencies, which a delegatecall cannot read for itself.
    struct Env {
        IPositionManager positionManager;
        MarketDebt.Env debt;
    }

    /// @notice Claims every fee `tokenId` has accrued to `to`, and keeps the position healthy.
    /// @dev Uniswap v4 has no collect action. `_decrease` realises the position's whole fee
    ///      balance however little liquidity it removes, so a `DECREASE_LIQUIDITY` of zero pays
    ///      out exactly the fees and never principal. `TAKE_PAIR` may address `to` directly,
    ///      unlike §8 step 5's partial seizure, because the fees belong to the caller.
    ///
    ///      **Recipients PositionManager would reinterpret are refused.** `TAKE_PAIR` reads
    ///      `address(1)` as its caller, which is this market, and `address(2)` as itself. The first
    ///      would leave the fees here, ETH included, where `rescueUnaccountedEth` would sweep them;
    ///      the second would leave them in PositionManager for anyone to take.
    ///
    ///      **The health factor is checked after the claim, because the claim is what lowers it**
    ///      (§7). With debt outstanding, the check runs §5.2's borrow price gates first (v0.40):
    ///      the fees would otherwise leave at a price the gates refuse to lend against.
    ///
    ///      **Nothing is written after the first outbound call** (§4.1 v0.26). The only write is
    ///      the accrual, and it comes first. Pool hooks and a native-ETH `to` run code during the
    ///      claim, but the market's cash, debt and reserves do not move here at all: the fees come
    ///      from PoolManager. A vault redeem made from inside that code is priced on the same
    ///      ledger as one made after. The health check that follows only reads, and reverts the
    ///      whole claim if it fails.
    function collectFees(
        Env calldata env,
        uint256 tokenId,
        address to
    ) external {
        MarketDebt.accrue(env.debt);
        if (uint160(to) <= uint160(ActionConstants.ADDRESS_THIS) || to == address(this)) revert InvalidRecipient(to);

        MarketLedger.Loan storage loan = MarketLedger.layout().loans[tokenId];
        if (loan.owner != msg.sender) revert NotTheDepositor(tokenId, loan.owner);

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(tokenId);
        uint256 amount0 = key.currency0.balanceOf(to);
        uint256 amount1 = key.currency1.balanceOf(to);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
        env.positionManager
            .modifyLiquidities(
                abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params),
                block.timestamp
            );

        amount0 = key.currency0.balanceOf(to) - amount0;
        amount1 = key.currency1.balanceOf(to) - amount1;

        MarketDebt.requireHealthy(env.debt, tokenId);
        emit CollectFees(tokenId, loan.poolKeyId, amount0, amount1);
    }
}
