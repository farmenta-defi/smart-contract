// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {MarketLens} from "../../src/MarketLens.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice Fork coverage for the debt ledger and ERC-4626 cash constraints.
/// @dev Uses the shared fork harness without re-running the custody suite.
contract MarketBorrowForkTest is MarketForkTest {
    address internal lender = address(0x1E4DE2);

    function _prepareLoan() internal returns (uint256 tokenId, address holder) {
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 50e18);
        holder = nft.ownerOf(tokenId);
        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(RobinhoodChain.USDG), lender, 300e6);
        vm.startPrank(lender);
        IERC20(address(RobinhoodChain.USDG)).approve(address(market), type(uint256).max);
        market.deposit(300e6, lender);
        vm.stopPrank();
    }

    function test_borrowUsesOracleValueAndRejectsAboveMaxLtv() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 allowed = lens.maxBorrow(tokenId) - 1000;
        assertGt(allowed, 10e6);

        vm.prank(holder);
        market.borrow(tokenId, allowed, holder);
        assertEq(market.debtOf(tokenId), allowed);

        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.BorrowExceedsMaxLtv.selector);
        market.borrow(tokenId, 200e6, holder);
    }

    function test_blueChipBorrowDoesNotRecordTwap() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        PoolKey memory key = _keyOf(tokenId);
        assertEq(oracle.recordCount(key.toId()), 0);

        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);
        assertEq(oracle.recordCount(key.toId()), 0);
    }

    function test_borrowRejectsAnUnverifiedOraclePrice() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);

        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.UsdgPriceOutOfBounds.selector);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowRejectsUsdgAboveTheDepegCeiling() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 1.0301e18, RobinhoodChain.USDG_DECIMALS);

        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.UsdgPriceOutOfBounds.selector);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowAcceptsInclusiveUsdgBounds() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.97e18, RobinhoodChain.USDG_DECIMALS);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2444e18, 18);
        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);

        oracle.set(Currency.wrap(RobinhoodChain.USDG), 1.03e18, RobinhoodChain.USDG_DECIMALS);
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2596e18, 18);
        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowRejectsFreshPythDeviation() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.setPythPrice(2600e18, block.timestamp);

        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.PythPriceDeviation.selector);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowIgnoresStalePyth() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.setPythPrice(1e18, block.timestamp - 10 minutes - 1);

        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowAcceptsFreshPythWithinThreePercent() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.setPythPrice(2550e18, block.timestamp);

        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowRejectsSpotOutsideTheTwoPercentGate() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2458e18, 18);
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        assertGt(valuation.spotDeviationBps, 200);
        assertLt(valuation.spotDeviationBps, 300);

        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.SpotPriceDeviation.selector);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowAcceptsSpotWithinTheTwoPercentGate() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2480e18, 18);
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        assertGt(valuation.spotDeviationBps, 100);
        assertLt(valuation.spotDeviationBps, 200);

        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);
    }

    function test_borrowCapacityUsesNinetyEightCentUsdPrice() public {
        (uint256 tokenId,) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.98e18, RobinhoodChain.USDG_DECIMALS);
        uint256 atNinetyEightCents = lens.maxBorrow(tokenId);
        ICollateralPolicy.Terms memory terms = policy.termsOf(_keyOf(tokenId).toId());
        uint256 expected = lens.positionValue(tokenId) * terms.maxLtvBps / 10_000 * 1e6 / 0.98e18;
        assertApproxEqAbs(atNinetyEightCents, expected, 1, "USDG oracle price must scale borrow capacity");
    }

    function test_memeBorrowSkipsPythAndSpotGates() public {
        vm.startPrank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.MEME, 18, address(1));
        vm.stopPrank();

        FarmentaMarket memeMarket = _deployMarket(ICollateralPolicy.Tier.MEME);
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        PoolKey memory key = _keyOf(tokenId);
        TierPresets.Preset memory preset = TierPresets.meme();
        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: 50e18
            })
        );

        address holder = nft.ownerOf(tokenId);
        vm.startPrank(holder);
        nft.approve(address(memeMarket), tokenId);
        memeMarket.depositCollateral(tokenId);
        vm.stopPrank();
        assertEq(oracle.recordCount(key.toId()), 1);

        deal(address(RobinhoodChain.USDG), lender, 300e6);
        vm.startPrank(lender);
        IERC20(address(RobinhoodChain.USDG)).approve(address(memeMarket), type(uint256).max);
        memeMarket.deposit(300e6, lender);
        vm.stopPrank();

        uint256 allowed = new MarketLens(memeMarket).maxBorrow(tokenId);
        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.BorrowExceedsMaxLtv.selector);
        memeMarket.borrow(tokenId, allowed + 1, holder);

        vm.prank(holder);
        memeMarket.borrow(tokenId, allowed, holder);
        assertEq(oracle.recordCount(key.toId()), 2);

        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);
        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.UsdgPriceOutOfBounds.selector);
        memeMarket.borrow(tokenId, 10e6, holder);
    }

    function test_repayMaxAfterAccrualClearsDebtAndAllowsWithdrawal() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = lens.maxBorrow(tokenId) / 2;
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

    function test_healthFactorUsesCappedFeesAndOraclePricedDebt() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.98e18, RobinhoodChain.USDG_DECIMALS);
        uint256 amount = lens.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);
        uint256 debtUsd = market.debtOf(tokenId) * 0.98e18 / 1e6;
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        uint256 collateralValue = (valuation.principalUsd + _min(valuation.feesUsd, valuation.principalUsd / 10))
            * (10_000 - policy.termsOf(_keyOf(tokenId).toId()).removeHaircutBps) / 10_000;
        uint256 expected = collateralValue * 7500 * 1e18 / (debtUsd * 10_000);
        assertEq(lens.positionValue(tokenId), collateralValue, "position value is the specified collateral value");
        assertApproxEqRel(lens.healthFactor(tokenId), expected, 1e12);
    }

    function test_healthFactorFallsBelowOneWhenCollateralPriceDrops() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);

        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2200e18, 18);
        assertGt(lens.healthFactor(tokenId), 1e18, "a price just above the boundary must remain healthy");

        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), 2100e18, 18);
        assertLt(lens.healthFactor(tokenId), 1e18, "a price just below the boundary must become unhealthy");
    }

    function test_maxWithdrawNeverExceedsCashAfterBorrow() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = lens.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);
        uint256 cash = IERC20(market.asset()).balanceOf(address(market));
        assertEq(market.maxWithdraw(lender), cash);
        assertEq(market.maxRedeem(lender), market.convertToShares(cash));

        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, lender, cash + 1, cash)
        );
        market.withdraw(cash + 1, lender, lender);
    }

    function test_borrowBelowTenDollarsReverts() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.BorrowBelowMinimum.selector, 9e6));
        market.borrow(tokenId, 9e6, holder);

        vm.prank(holder);
        market.borrow(tokenId, 10e6, holder);
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
        vm.startPrank(holder);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();
        deal(address(RobinhoodChain.USDG), address(market), 1_000_000e6);

        vm.prank(holder);
        market.borrow(tokenId, 50e6, holder);
        vm.prank(holder);
        vm.expectPartialRevert(FarmentaMarket.PoolDebtCapExceeded.selector);
        market.borrow(tokenId, 60e6, holder);
    }

    function test_accrualAddsInterestAndReserves() public {
        (uint256 tokenId, address holder) = _prepareLoan();
        uint256 amount = lens.maxBorrow(tokenId) / 2;
        vm.prank(holder);
        market.borrow(tokenId, amount, holder);
        uint256 before = market.totalBorrows();
        vm.warp(block.timestamp + 365 days);
        market.accrue();
        uint256 afterBorrows = market.totalBorrows();
        uint256 interest = afterBorrows - before;
        uint256 utilization = before * 1e18 / (300e6 - amount + before);
        uint256 rate = market.interestRateModel().ratePerSecond(market.tier(), utilization);
        uint256 expectedInterest = before * rate * 365 days / 1e18;
        assertApproxEqAbs(interest, expectedInterest, 1, "interest follows the rate curve");
        assertEq(market.reserves(), interest * 1500 / 10_000, "reserves are 15% of interest");
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
