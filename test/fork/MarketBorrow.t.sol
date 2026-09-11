// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketCustodyForkTest} from "./MarketCustody.t.sol";

/// @notice Fork coverage for the debt ledger and ERC-4626 cash constraints.
/// @dev Reuses the custody harness so every test values a real Uniswap position.
contract MarketBorrowForkTest is MarketCustodyForkTest {
    function _prepareLoan() internal returns (uint256 tokenId, address holder) {
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 50e18);
        holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);
        deal(address(RobinhoodChain.USDG), address(market), 1_000_000e6);
    }

    function test_borrowUsesOracleValueAndRejectsAboveMaxLtv() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 allowed = market.maxBorrow(tokenId) - 1000;
        assertGt(allowed, 10e6);

        vm.prank(holder);
        market.borrow(tokenId, allowed, holder);
        assertEq(market.debtOf(tokenId), allowed);

        vm.prank(holder);
        vm.expectRevert();
        market.borrow(tokenId, 200e6, holder);
    }

    function test_repayMaxAfterAccrualClearsDebtAndAllowsWithdrawal() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = market.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);

        vm.warp(block.timestamp + 365 days);
        market.accrue();
        uint256 debt = market.debtOf(tokenId);
        deal(address(RobinhoodChain.USDG), holder, debt);
        vm.startPrank(holder);
        IERC20(address(RobinhoodChain.USDG)).approve(address(market), debt);
        market.repay(tokenId, type(uint256).max);
        market.withdrawCollateral(tokenId, holder);
        vm.stopPrank();
        assertEq(market.debtOf(tokenId), 0);
    }

    function test_healthFactorUsesPrincipalOnly() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = market.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);
        uint256 debtUsd = market.debtOf(tokenId) * 1e12;
        uint256 expected = market.positionValue(tokenId) * 7500 * 1e18 / (debtUsd * 10_000);
        assertApproxEqRel(market.healthFactor(tokenId), expected, 1e12);
    }

    function test_maxWithdrawNeverExceedsCashAfterBorrow() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = market.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);
        assertLe(market.maxWithdraw(holder), IERC20(market.asset()).balanceOf(address(market)));
        assertLe(market.maxRedeem(holder), market.balanceOf(holder));
    }

    function test_borrowBelowTenDollarsReverts() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        vm.prank(holder);
        vm.expectRevert();
        market.borrow(tokenId, 9e6, holder);
    }

    function test_poolDebtCapRejectsAnotherBorrow() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        PoolKey memory key = _keyOf(tokenId);
        TierPresets.Preset memory preset = TierPresets.blueChip();
        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: 100e6,
                minPositionUsd: 50e18
            })
        );
        address holder = nft.ownerOf(tokenId);
        _deposit(tokenId, holder);
        deal(address(RobinhoodChain.USDG), address(market), 1_000_000e6);

        vm.prank(holder);
        market.borrow(tokenId, 50e6, holder);
        vm.prank(holder);
        vm.expectRevert();
        market.borrow(tokenId, 60e6, holder);
    }

    function test_accrualAddsInterestAndReserves() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = market.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);
        uint256 before = market.totalBorrows();
        vm.warp(block.timestamp + 365 days);
        market.accrue();
        assertGt(market.totalBorrows(), before);
        assertGt(market.reserves(), 0);
    }
}
