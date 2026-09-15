// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";

/// @notice A lender that liquidates into its own address and redeems its vault shares from
///         inside the ETH payout.
/// @dev The ERC-4626 exits are not behind the market's reentrancy guard, and nothing a lender
///      does needs them to be. So what stands between this contract and a share price read
///      halfway through a liquidation is only the order in which `MarketLiquidation` works.
contract RedeemingLiquidator {
    FarmentaMarket internal immutable market;
    bool internal armed;

    /// @notice What the redemption made from inside the payout paid out.
    uint256 public redeemed;

    constructor(
        FarmentaMarket market_
    ) {
        market = market_;
        IERC20(market_.asset()).approve(address(market_), type(uint256).max);
    }

    function deposit(
        uint256 assets
    ) external {
        market.deposit(assets, address(this));
    }

    function liquidate(
        uint256 tokenId,
        uint256 repayAmount
    ) external returns (uint256 badDebt) {
        armed = true;
        (,,, badDebt) = market.liquidate(tokenId, repayAmount, 0, 0, address(this));
        armed = false;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        redeemed = market.redeem(market.balanceOf(address(this)), address(this), address(this));
    }
}
