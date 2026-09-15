// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RobinhoodChain} from "../constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {DebtMath} from "./DebtMath.sol";
import {MarketLedger} from "./MarketLedger.sol";
import {TierPresets} from "./TierPresets.sol";

/// @title MarketDebt
/// @notice Linked debt-accounting execution for `FarmentaMarket`.
/// @dev Runs by delegatecall, so it writes the calling market's ERC-7201 layout and preserves
///      `msg.sender`, events, and transfers while keeping this code outside the implementation.
library MarketDebt {
    using SafeERC20 for IERC20;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_SPOT_DEVIATION_BPS = 200;
    uint256 private constant MAX_PYTH_PRICE_AGE = 10 minutes;
    uint256 private constant MAX_PYTH_DEVIATION_BPS = 300;
    uint256 private constant USDG_MIN_PRICE = 0.97e18;
    uint256 private constant USDG_MAX_PRICE = 1.03e18;

    event Borrow(uint256 indexed tokenId, uint256 amount);
    event Repay(uint256 indexed tokenId, uint256 amount);
    event ReservesUpdated(uint256 reserves);

    error BorrowerNotAuthorized(uint256 tokenId, address borrower);
    error InvalidBorrowRecipient(address to);
    error BorrowExceedsMaxLtv(uint256 requestedDebt, uint256 maximumDebt);
    error BorrowBelowMinimum(uint256 debt);
    error ZeroBorrowAmount();
    error PoolDebtCapExceeded(PoolId poolId, uint256 requestedDebt, uint256 debtCap);
    error MarketDebtCapExceeded(uint256 requestedDebt, uint256 debtCap);
    error PoolNotOpenForBorrowing(PoolId poolId);
    error SpotPriceDeviation(uint256 deviationBps, uint256 maximumDeviationBps);
    error UsdgPriceOutOfBounds(uint256 price);
    error PythPriceDeviation(uint256 chainlinkPrice, uint256 pythPrice);
    error PositionWouldBeUnhealthy(uint256 tokenId, uint256 healthFactor);

    struct Env {
        IERC20 asset;
        ICollateralPolicy policy;
        IPositionValuer valuer;
        IPriceOracle oracle;
        IInterestRateModel interestRateModel;
    }

    function accrue(
        Env calldata env
    ) external {
        _accrue(env);
    }

    function borrow(
        Env calldata env,
        uint256 tokenId,
        uint256 amount,
        address to
    ) external {
        if (to == address(0) || to == address(this)) revert InvalidBorrowRecipient(to);
        if (amount == 0) revert ZeroBorrowAmount();
        _accrue(env);

        MarketLedger.Layout storage $ = MarketLedger.layout();
        MarketLedger.Loan storage loan = $.loans[tokenId];
        if (loan.owner != msg.sender) revert BorrowerNotAuthorized(tokenId, msg.sender);
        if (!env.policy.acceptsNewPositions(loan.poolKeyId)) revert PoolNotOpenForBorrowing(loan.poolKeyId);

        {
            (ICollateralPolicy.Terms memory terms, uint256 collateralUsd) =
                _gatedCollateralValue(env, $.tier, loan.poolKeyId, tokenId);
            uint256 requestedDebt = DebtMath.debtOf(loan.debtShares, $.borrowIndex) + amount;
            uint256 requestedDebtUsd = _debtUsd(env.asset, env.oracle, requestedDebt);
            uint256 maximumDebtUsd = collateralUsd * terms.maxLtvBps / BPS;
            if (requestedDebtUsd > maximumDebtUsd) revert BorrowExceedsMaxLtv(requestedDebtUsd, maximumDebtUsd);
            if (requestedDebt < 10e6) revert BorrowBelowMinimum(requestedDebt);

            uint256 requestedPoolDebt = DebtMath.debtOf($.poolDebtShares[loan.poolKeyId], $.borrowIndex) + amount;
            if (requestedPoolDebt > terms.debtCapUsdg) {
                revert PoolDebtCapExceeded(loan.poolKeyId, requestedPoolDebt, terms.debtCapUsdg);
            }
        }

        uint256 marketDebtCap = TierPresets.forTier($.tier).marketDebtCapUsdg;
        if ($.totalBorrows + amount > marketDebtCap) {
            revert MarketDebtCapExceeded($.totalBorrows + amount, marketDebtCap);
        }

        uint256 shares = DebtMath.sharesForBorrow(amount, $.borrowIndex);
        loan.debtShares += shares;
        $.totalBorrowShares += shares;
        $.poolDebtShares[loan.poolKeyId] += shares;
        $.totalBorrows = DebtMath.debtOf($.totalBorrowShares, $.borrowIndex);
        env.asset.safeTransfer(to, amount);
        emit Borrow(tokenId, amount);
    }

    function repay(
        Env calldata env,
        uint256 tokenId,
        uint256 amount
    ) external returns (uint256 repaid) {
        _accrue(env);
        MarketLedger.Layout storage $ = MarketLedger.layout();
        MarketLedger.Loan storage loan = $.loans[tokenId];
        uint256 debt = DebtMath.debtOf(loan.debtShares, $.borrowIndex);
        if (amount == type(uint256).max || amount > debt) amount = debt;
        if (amount == 0) return 0;

        uint256 shares = amount == debt ? loan.debtShares : DebtMath.sharesForRepay(amount, $.borrowIndex);
        repaid = DebtMath.debtOf(shares, $.borrowIndex);
        loan.debtShares -= shares;
        $.totalBorrowShares -= shares;
        $.poolDebtShares[loan.poolKeyId] -= shares;
        $.totalBorrows = DebtMath.debtOf($.totalBorrowShares, $.borrowIndex);
        env.asset.safeTransferFrom(msg.sender, address(this), repaid);
        emit Repay(tokenId, repaid);
    }

    /// @notice Refuses to leave `tokenId` under water once an action has taken value out of it:
    ///         §7's post-condition on a borrower action, checked where the action is complete.
    /// @dev Nothing owed means nothing to protect, so with no debt neither the price gates nor
    ///      the health factor run (§5.2 v0.40). Otherwise the health factor is §6.2's, priced with
    ///      `price` exactly as `MarketLens.healthFactor` prices it, and read through the same gates
    ///      as `borrow`: value must not leave a position at a price the market refuses to lend
    ///      against.
    ///
    ///      A view, which is what makes it safe to run after the action's outbound calls: it writes
    ///      nothing, and a refusal reverts the action along with it.
    function requireHealthy(
        Env calldata env,
        uint256 tokenId
    ) external view {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        MarketLedger.Loan storage loan = $.loans[tokenId];
        uint256 debt = DebtMath.debtOf(loan.debtShares, $.borrowIndex);
        if (debt == 0) return;

        (ICollateralPolicy.Terms memory terms, uint256 collateralUsd) =
            _gatedCollateralValue(env, $.tier, loan.poolKeyId, tokenId);
        uint256 healthFactor = DebtMath.healthFactor(collateralUsd, terms.ltBps, _debtUsd(env.asset, env.oracle, debt));
        if (healthFactor < WAD) revert PositionWouldBeUnhealthy(tokenId, healthFactor);
    }

    function _accrue(
        Env calldata env
    ) private {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        uint256 elapsed = block.timestamp - $.lastAccrual;
        if (elapsed == 0) return;

        $.lastAccrual = block.timestamp;
        if ($.totalBorrowShares == 0) return;

        uint256 cash = env.asset.balanceOf(address(this));
        uint256 utilization = $.totalBorrows * WAD / (cash + $.totalBorrows);
        uint256 rate = env.interestRateModel.ratePerSecond($.tier, utilization);
        (uint256 newIndex, uint256 newTotalBorrows, uint256 interest) =
            DebtMath.accrue($.borrowIndex, $.totalBorrowShares, $.totalBorrows, rate, elapsed);

        $.borrowIndex = newIndex;
        $.totalBorrows = newTotalBorrows;
        $.reserves += interest * $.reserveFactorBps / BPS;
        emit ReservesUpdated($.reserves);
    }

    /// @dev A position's §6.2 collateral value, read only once §5.2's borrow price gates pass: USDG
    ///      inside [0,97; 1,03], a fresh Pyth quote within 3% of Chainlink, and a blue-chip pool
    ///      within 2% of the oracle. One function, so every action that sizes risk off this value
    ///      refuses at the same prices.
    function _gatedCollateralValue(
        Env calldata env,
        ICollateralPolicy.Tier tier,
        PoolId poolId,
        uint256 tokenId
    ) private view returns (ICollateralPolicy.Terms memory terms, uint256 collateralUsd) {
        terms = env.policy.termsOf(poolId);
        _checkBorrowPrice(env, tier);
        IPositionValuer.Valuation memory valuation = env.valuer.value(tokenId);
        if (tier == ICollateralPolicy.Tier.BLUE_CHIP && valuation.spotDeviationBps > MAX_SPOT_DEVIATION_BPS) {
            revert SpotPriceDeviation(valuation.spotDeviationBps, MAX_SPOT_DEVIATION_BPS);
        }
        collateralUsd = DebtMath.collateralValue(valuation.principalUsd, valuation.feesUsd, terms.removeHaircutBps);
    }

    function _checkBorrowPrice(
        Env calldata env,
        ICollateralPolicy.Tier borrowTier
    ) private view {
        uint256 usdgPrice = env.oracle.price(env.policy.quote());
        if (usdgPrice < USDG_MIN_PRICE || usdgPrice > USDG_MAX_PRICE) revert UsdgPriceOutOfBounds(usdgPrice);
        if (borrowTier != ICollateralPolicy.Tier.BLUE_CHIP) return;

        (uint256 pythPrice, uint256 publishTime) = env.oracle.pythEthUsd();
        if (publishTime == 0 || publishTime > block.timestamp || block.timestamp - publishTime > MAX_PYTH_PRICE_AGE) {
            return;
        }

        uint256 chainlinkPrice = env.oracle.price(Currency.wrap(RobinhoodChain.NATIVE));
        uint256 difference = chainlinkPrice > pythPrice ? chainlinkPrice - pythPrice : pythPrice - chainlinkPrice;
        if (Math.mulDiv(difference, BPS, chainlinkPrice) > MAX_PYTH_DEVIATION_BPS) {
            revert PythPriceDeviation(chainlinkPrice, pythPrice);
        }
    }

    function _debtUsd(
        IERC20 asset,
        IPriceOracle oracle,
        uint256 debt
    ) private view returns (uint256) {
        Currency assetCurrency = Currency.wrap(address(asset));
        return DebtMath.debtUsd(debt, oracle.price(assetCurrency), oracle.decimals(assetCurrency));
    }
}
