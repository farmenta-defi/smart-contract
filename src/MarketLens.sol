// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FarmentaMarket} from "./FarmentaMarket.sol";
import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "./interfaces/IPositionValuer.sol";
import {DebtMath} from "./libraries/DebtMath.sol";

/// @title MarketLens
/// @notice Read-only risk and reserve views for one FarmentaMarket proxy.
/// @dev Stateless and not upgradeable. Deploy a replacement lens when its view surface changes.
contract MarketLens {
    uint256 private constant BPS = 10_000;

    FarmentaMarket public immutable market;

    constructor(
        FarmentaMarket market_
    ) {
        market = market_;
    }

    /// @notice Collateral value available to borrow against after fee cap and removal haircut.
    function positionValue(
        uint256 tokenId
    ) public view returns (uint256) {
        FarmentaMarket.Loan memory loan = market.loanOf(tokenId);
        if (loan.owner == address(0)) return 0;

        ICollateralPolicy.Terms memory terms = market.policy().termsOf(loan.poolKeyId);
        IPositionValuer.Valuation memory valuation = market.valuer().value(tokenId);
        uint256 cappedFees = Math.min(valuation.feesUsd, valuation.principalUsd / 10);
        return (valuation.principalUsd + cappedFees) * (BPS - terms.removeHaircutBps) / BPS;
    }

    /// @notice Additional USDG that `tokenId` may borrow without crossing max LTV.
    function maxBorrow(
        uint256 tokenId
    ) external view returns (uint256) {
        FarmentaMarket.Loan memory loan = market.loanOf(tokenId);
        if (loan.owner == address(0)) return 0;

        uint256 maximumDebtUsd = positionValue(tokenId) * market.policy().termsOf(loan.poolKeyId).maxLtvBps / BPS;
        uint256 debtUsd = _debtUsd(market.debtOf(tokenId));
        if (maximumDebtUsd <= debtUsd) return 0;
        return _usdToDebt(maximumDebtUsd - debtUsd);
    }

    /// @notice Liquidation health factor, scaled by 1e18.
    function healthFactor(
        uint256 tokenId
    ) external view returns (uint256) {
        uint256 debt = market.debtOf(tokenId);
        if (debt == 0) return type(uint256).max;

        FarmentaMarket.Loan memory loan = market.loanOf(tokenId);
        uint256 debtUsd = _debtUsd(debt);
        return DebtMath.healthFactor(positionValue(tokenId), market.policy().termsOf(loan.poolKeyId).ltBps, debtUsd);
    }

    /// @notice Lender-protection reserve floor for the market's current cash balance.
    function reserveFloor() public view returns (uint256) {
        return market.totalAssets() * _reserveFloorBps() / BPS;
    }

    /// @notice Reserve revenue currently available for owner withdrawal, capped by cash.
    function withdrawableReserves() external view returns (uint256) {
        uint256 floor = reserveFloor();
        uint256 reserves = market.reserves();
        if (reserves <= floor) return 0;
        return Math.min(reserves - floor, IERC20(market.asset()).balanceOf(address(market)));
    }

    function _debtUsd(
        uint256 debt
    ) private view returns (uint256) {
        Currency assetCurrency = Currency.wrap(market.asset());
        return DebtMath.debtUsd(debt, market.oracle().price(assetCurrency), market.oracle().decimals(assetCurrency));
    }

    function _usdToDebt(
        uint256 usdValue
    ) private view returns (uint256) {
        Currency assetCurrency = Currency.wrap(market.asset());
        return
            DebtMath.usdToDebt(usdValue, market.oracle().price(assetCurrency), market.oracle().decimals(assetCurrency));
    }

    function _reserveFloorBps() private view returns (uint256) {
        return market.tier() == ICollateralPolicy.Tier.BLUE_CHIP ? 100 : 250;
    }
}
