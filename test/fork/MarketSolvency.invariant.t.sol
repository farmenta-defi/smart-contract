// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

/// @notice Restricts invariant fuzzing to valid lender and borrower actions.
contract MarketHandler is Test {
    FarmentaMarket internal immutable market;
    IERC20 internal immutable usdg;
    uint256 internal immutable tokenId;
    address internal immutable borrower;
    address internal immutable lender;
    address internal immutable owner;

    constructor(
        FarmentaMarket market_,
        uint256 tokenId_,
        address borrower_,
        address lender_,
        address owner_
    ) {
        market = market_;
        usdg = IERC20(market_.asset());
        tokenId = tokenId_;
        borrower = borrower_;
        lender = lender_;
        owner = owner_;
    }

    function borrow(
        uint256 amount
    ) external {
        uint256 maximum = market.maxBorrow(tokenId);
        if (maximum < 10e6) return;
        amount = bound(amount, 10e6, maximum);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        assertGe(market.healthFactor(tokenId), 1e18, "borrow accepted an unhealthy position");
    }

    function repay(
        uint256 amount
    ) external {
        uint256 debt = market.debtOf(tokenId);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        deal(address(usdg), borrower, amount);
        vm.startPrank(borrower);
        usdg.approve(address(market), amount);
        market.repay(tokenId, amount);
        vm.stopPrank();
    }

    function deposit(
        uint256 amount
    ) external {
        amount = bound(amount, 1, 100e6);
        deal(address(usdg), lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(market), amount);
        market.deposit(amount, lender);
        vm.stopPrank();
    }

    function withdraw(
        uint256 amount
    ) external {
        uint256 maximum = market.maxWithdraw(lender);
        if (maximum == 0) return;
        amount = bound(amount, 1, maximum);
        vm.prank(lender);
        market.withdraw(amount, lender, lender);
    }

    function withdrawReserves(
        uint256 amount
    ) external {
        uint256 maximum = market.withdrawableReserves();
        if (maximum == 0) return;
        amount = bound(amount, 1, maximum);
        vm.prank(owner);
        market.withdrawReserves(amount, owner);
    }

    function passTime(
        uint40 elapsed
    ) external {
        uint256 oneShare = 10 ** market.decimals();
        uint256 assetsBefore = market.convertToAssets(oneShare);
        vm.warp(block.timestamp + bound(uint256(elapsed), 1 hours, 30 days));
        market.accrue();
        assertGe(market.convertToAssets(oneShare), assetsBefore, "accrual reduced the vault share price");
    }
}

/// @notice Solvency assertions over a real fork position after a user borrow action.
/// @dev This suite intentionally lives in the fork lane: it values a real Uniswap position.
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 32
contract MarketSolvencyInvariantTest is MarketForkTest {
    uint256 internal tokenId;
    MarketHandler internal handler;
    address internal borrower;
    address internal lender = address(0x1E4DE2);

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 50e18);
        borrower = nft.ownerOf(tokenId);
        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(market.asset(), lender, 300e6);
        vm.startPrank(lender);
        IERC20(market.asset()).approve(address(market), type(uint256).max);
        market.deposit(300e6, lender);
        vm.stopPrank();

        uint256 amount = market.maxBorrow(tokenId) / 2;
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        handler = new MarketHandler(market, tokenId, borrower, lender, market.owner());
        targetContract(address(handler));
    }

    function invariant_totalBorrowsMatchesBorrowSharesAndIndex() public view {
        assertEq(market.totalBorrows(), market.totalBorrowShares() * market.borrowIndex() / 1e18);
    }

    function invariant_reservesStayNonNegative() public view {
        assertGe(market.reserves(), 0);
    }

    function invariant_withdrawableNeverExceedsCash() public view {
        assertLe(market.withdrawableReserves(), IERC20(market.asset()).balanceOf(address(market)));
    }
}
