// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {FarmentaMarketV2Mock} from "../mocks/FarmentaMarketV2Mock.sol";

/// @notice Fork proof that an upgrade preserves a populated lending book.
contract StorageLayoutTest is MarketForkTest {
    address internal constant LENDER = address(0x1E4DE2);
    address internal constant STRANGER = address(0xBAD);

    struct Snapshot {
        FarmentaMarket.Loan loan;
        uint256 debt;
        uint256 poolDebt;
        uint256 totalBorrows;
        uint256 borrowShares;
        uint256 index;
        uint256 reserves;
        ICollateralPolicy.Terms terms;
    }

    function test_upgradePreservesLoanReservesAndRamp() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 50e18);
        address borrower = nft.ownerOf(tokenId);

        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(RobinhoodChain.USDG), LENDER, 300e6);
        vm.startPrank(LENDER);
        IERC20(RobinhoodChain.USDG).approve(address(market), type(uint256).max);
        market.deposit(300e6, LENDER);
        vm.stopPrank();

        uint256 borrowed = market.maxBorrow(tokenId) / 2;
        vm.prank(borrower);
        market.borrow(tokenId, borrowed, borrower);

        vm.warp(block.timestamp + 30 days);
        market.accrue();
        assertGt(market.reserves(), 0, "fixture must accrue reserves");

        PoolId poolId = _keyOf(tokenId).toId();
        vm.prank(owner);
        policy.scheduleLtRamp(poolId, 7000, uint40(block.timestamp + 1 days), 30 days);
        vm.warp(block.timestamp + 16 days);

        Snapshot memory before = _snapshot(tokenId, poolId);

        FarmentaMarketV2Mock next = _deployV2();
        vm.prank(owner);
        market.upgradeToAndCall(address(next), "");

        FarmentaMarketV2Mock upgraded = FarmentaMarketV2Mock(payable(address(market)));
        _assertSnapshot(upgraded, tokenId, poolId, before);

        vm.prank(owner);
        upgraded.setUpgradeMarker(42);
        assertEq(upgraded.upgradeMarker(), 42, "new namespace is unusable");
    }

    function test_upgradeAndInitializersRemainProtected() public {
        FarmentaMarketV2Mock next = _deployV2();

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        market.upgradeToAndCall(address(next), "");

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        next.initialize(IERC20(RobinhoodChain.USDG), "x", "x", ICollateralPolicy.Tier.BLUE_CHIP, owner);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        market.initialize(IERC20(RobinhoodChain.USDG), "x", "x", ICollateralPolicy.Tier.BLUE_CHIP, owner);
    }

    function _deployV2() private returns (FarmentaMarketV2Mock) {
        return FarmentaMarketV2Mock(
            payable(address(new FarmentaMarketV2Mock(positionManager, policy, valuer, oracle, interestRateModel)))
        );
    }

    function _snapshot(
        uint256 tokenId,
        PoolId poolId
    ) private view returns (Snapshot memory snapshot) {
        snapshot.loan = market.loanOf(tokenId);
        snapshot.debt = market.debtOf(tokenId);
        snapshot.poolDebt = market.poolDebt(poolId);
        snapshot.totalBorrows = market.totalBorrows();
        snapshot.borrowShares = market.totalBorrowShares();
        snapshot.index = market.borrowIndex();
        snapshot.reserves = market.reserves();
        snapshot.terms = policy.termsOf(poolId);
    }

    function _assertSnapshot(
        FarmentaMarket upgraded,
        uint256 tokenId,
        PoolId poolId,
        Snapshot memory before
    ) private view {
        FarmentaMarket.Loan memory loanAfter = upgraded.loanOf(tokenId);
        assertEq(uint8(upgraded.tier()), uint8(ICollateralPolicy.Tier.BLUE_CHIP), "tier shifted");
        assertEq(upgraded.owner(), owner, "owner shifted");
        assertEq(loanAfter.owner, before.loan.owner, "loan owner shifted");
        assertEq(uint8(loanAfter.tier), uint8(before.loan.tier), "loan tier shifted");
        assertEq(loanAfter.debtShares, before.loan.debtShares, "loan shares shifted");
        assertEq(PoolId.unwrap(loanAfter.poolKeyId), PoolId.unwrap(before.loan.poolKeyId), "loan pool shifted");
        assertEq(upgraded.debtOf(tokenId), before.debt, "debt shifted");
        assertEq(upgraded.poolDebt(poolId), before.poolDebt, "pool debt shifted");
        assertEq(upgraded.totalBorrows(), before.totalBorrows, "total borrows shifted");
        assertEq(upgraded.totalBorrowShares(), before.borrowShares, "borrow shares shifted");
        assertEq(upgraded.borrowIndex(), before.index, "borrow index shifted");
        assertEq(upgraded.reserves(), before.reserves, "reserves shifted");
        assertEq(policy.termsOf(poolId).ltBps, before.terms.ltBps, "ramp shifted");
    }
}
