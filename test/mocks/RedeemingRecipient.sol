// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";

/// @notice A lender that is also where a borrower's fees are sent, and redeems its vault shares
///         from inside the ETH that `collectFees` pays it.
/// @dev The `collectFees` counterpart of `RedeemingLiquidator` (§4.1 v0.26): the ERC-4626 exits are
///      not behind the market's guard, so a redeem can run while the claim is still in flight.
contract RedeemingRecipient {
    FarmentaMarket internal immutable market;
    bool internal armed;

    /// @notice What the redemption made from inside the payout paid out.
    uint256 public redeemed;

    /// @notice This contract's USDG balance when the ETH arrived, read before anything else runs.
    uint256 public usdgOnEthArrival;

    /// @notice The market's borrow index when the ETH arrived.
    /// @dev The payout is an outbound call, and §4.1 v0.26 wants every write done before the first
    ///      one. An index still at its pre-accrual value here means the accrual came after.
    uint256 public borrowIndexOnEthArrival;

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

    /// @notice Redeems everything on the next ETH to arrive.
    function arm() external {
        armed = true;
    }

    receive() external payable {
        usdgOnEthArrival = IERC20(market.asset()).balanceOf(address(this));
        borrowIndexOnEthArrival = market.borrowIndex();
        if (!armed) return;
        armed = false;
        redeemed = market.redeem(market.balanceOf(address(this)), address(this), address(this));
    }
}
