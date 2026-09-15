// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
    /// @dev `amount0`/`amount1` are `to`'s balance change across the claim, not the fees the position
    ///      realised. Anything else reaching `to` while its ETH callback runs is counted as well, a vault
    ///      redeem or a transfer from anyone, so indexers (§13) must not treat these figures as verified
    ///      fee income. A `to` that sends out more than it received during that callback makes the claim
    ///      revert with an arithmetic panic.
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
    ///      out exactly the fees and never principal. The fees may go to `to` directly, unlike §8
    ///      step 5's partial seizure, because they belong to the caller.
    ///
    ///      **The borrow asset leaves first** (§4.1 v0.26, v0.40). Each leg is its own `TAKE`, USDG
    ///      before the other. `TAKE_PAIR` would pay `currency0` first, which in a native-ETH pool is
    ///      the ETH, and ETH runs the recipient's code before the USDG has left. None of the
    ///      market's own cash moves on this path either way; the order is kept so that no function
    ///      is an exception to the rule.
    ///
    ///      **Recipients PositionManager would not actually pay are refused** (§4.1 v0.43). See
    ///      `refusesRecipient`.
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
        if (refusesRecipient(env.positionManager, to)) revert InvalidRecipient(to);

        MarketLedger.Loan storage loan = MarketLedger.layout().loans[tokenId];
        if (loan.owner != msg.sender) revert NotTheDepositor(tokenId, loan.owner);

        (PoolKey memory key,) = env.positionManager.getPoolAndPositionInfo(tokenId);
        uint256 amount0 = key.currency0.balanceOf(to);
        uint256 amount1 = key.currency1.balanceOf(to);

        (Currency first, Currency second) = Currency.unwrap(key.currency1) == address(env.debt.asset)
            ? (key.currency1, key.currency0)
            : (key.currency0, key.currency1);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(first, to, uint256(ActionConstants.OPEN_DELTA));
        params[2] = abi.encode(second, to, uint256(ActionConstants.OPEN_DELTA));
        env.positionManager
            .modifyLiquidities(
                abi.encode(
                    abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE), uint8(Actions.TAKE)),
                    params
                ),
                block.timestamp
            );

        amount0 = key.currency0.balanceOf(to) - amount0;
        amount1 = key.currency1.balanceOf(to) - amount1;

        MarketDebt.requireHealthy(env.debt, tokenId);
        emit CollectFees(tokenId, loan.poolKeyId, amount0, amount1);
    }

    /// @notice Whether `to` is refused as the recipient of a payout PositionManager makes for this
    ///         market (§4.1 v0.43, decided on PR #18).
    /// @dev One rule for every such payout: `collectFees` here, `decreaseLiquidity` (FAR-8), and both
    ///      branches of `liquidate` (FAR-46), which is why it is `internal` and shared rather than
    ///      written into each function.
    ///
    ///      - `address(0)`: nowhere.
    ///      - This market: the payout would sit here, where `rescueUnaccountedEth` sweeps ETH and no
    ///        ERC-20 has a way out.
    ///      - `address(1)`: `TAKE` reads it as its caller, which is this market again.
    ///      - `address(2)` and PositionManager itself: the payout stays in PositionManager's balance,
    ///        and anyone can take it with `SWEEP` (proved on a fork in the review of PR #18).
    function refusesRecipient(
        IPositionManager positionManager,
        address to
    ) internal view returns (bool) {
        return
            uint160(to) <= uint160(ActionConstants.ADDRESS_THIS) || to == address(this)
                || to == address(positionManager);
    }
}
