// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";

/// @notice A pool hook that holds vault shares and redeems all of them while liquidity is being
///         added to its pool.
/// @dev The ERC-4626 exits are not behind the market's reentrancy guard (§4.1 v0.26), so a
///      hook can redeem from inside any market call that adds liquidity. If the caller's tokens
///      sat in the market at that moment they would count toward `totalAssets`, and the shares
///      would redeem at a price the caller's own money had inflated. Deploy it at an address
///      carrying `AFTER_ADD_LIQUIDITY_FLAG`. With no shares it does nothing, so a position can be
///      minted into its pool before it deposits.
contract VaultRedeemingHook {
    FarmentaMarket internal immutable market;

    /// @notice What the redemption made from inside the addition paid out.
    uint256 public redeemed;

    constructor(
        FarmentaMarket market_
    ) {
        market = market_;
    }

    function deposit(
        uint256 assets
    ) external {
        IERC20(market.asset()).approve(address(market), assets);
        market.deposit(assets, address(this));
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        uint256 shares = market.balanceOf(address(this));
        if (shares != 0) redeemed = market.redeem(shares, address(this), address(this));
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
