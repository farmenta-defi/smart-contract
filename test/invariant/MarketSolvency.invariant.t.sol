// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketBorrowForkTest} from "../fork/MarketBorrow.t.sol";

/// @notice Solvency assertions over a real fork position after a user borrow action.
contract MarketSolvencyInvariantTest is MarketBorrowForkTest {
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        address holder;
        (tokenId, holder) = _prepareLoan();
        uint256 amount = market.maxBorrow(tokenId) / 2;
        vm.startPrank(holder);
        market.borrow(tokenId, amount, holder);
        vm.stopPrank();
    }

    function invariant_userBorrowLeavesHealthFactorAboveOne() public view {
        assertGe(market.healthFactor(tokenId), 1e18);
    }

    function invariant_vaultAssetsCoverCashAndReserves() public view {
        assertGe(market.totalAssets(), market.reserves());
    }
}
