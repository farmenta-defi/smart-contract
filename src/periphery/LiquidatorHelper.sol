// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {RobinhoodChain} from "../constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";

interface IFlashLoanMorpho {
    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external;
}

interface ILiquidationMarket {
    function asset() external view returns (IERC20);

    function policy() external view returns (ICollateralPolicy);

    function positionManager() external view returns (IPositionManager);

    function liquidate(
        uint256 tokenId,
        uint256 repayAmount,
        uint128 minOut0,
        uint128 minOut1,
        address to
    ) external returns (uint256 repaid, uint256 out0, uint256 out1, uint256 badDebt);
}

/// @title LiquidatorHelper
/// @notice Makes a Farmenta liquidation, the collateral swap, and a Morpho flash loan one transaction.
/// @dev `swapCalldata` is assembled off-chain and carries its own minimum output. The helper
///      pushes the complete seized balance to UniversalRouter; the route must use
///      `SETTLE(..., CONTRACT_BALANCE, false)` and `OPEN_DELTA` so small price movements do not
///      turn a valid liquidation into a residual-balance revert.
contract LiquidatorHelper {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    error UnauthorizedMorpho(address caller);
    error ZeroRepayAmount();
    error SwapFailed(bytes reason);
    error ResidualBalance(address token, uint256 balance);

    ILiquidationMarket public immutable market;
    IFlashLoanMorpho public immutable morpho;
    IERC20 public immutable usdg;
    IPositionManager public immutable positionManager;
    address public immutable universalRouter;

    constructor(
        ILiquidationMarket market_,
        IFlashLoanMorpho morpho_,
        address universalRouter_
    ) {
        market = market_;
        morpho = morpho_;
        usdg = market_.asset();
        positionManager = market_.positionManager();
        universalRouter = universalRouter_;
    }

    receive() external payable {}

    /// @notice Flash-borrows the USDG budget, liquidates, swaps the non-USDG leg, and pays profit to the caller.
    /// @param tokenId The collateral position to liquidate.
    /// @param repayAmount The market repayment budget, including any retained-fee purchase budget.
    ///        The amount is borrowed in full, so callers should include a safety margin for
    ///        close-factor and interest movement; Morpho's atomic pull reverts if it is short.
    /// @param swapCalldata UniversalRouter calldata, quoted off-chain with its minimum output.
    function execute(
        uint256 tokenId,
        uint256 repayAmount,
        bytes calldata swapCalldata
    ) external {
        if (repayAmount == 0) revert ZeroRepayAmount();

        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        uint256 flashAmount = _flashAmount(key, repayAmount);
        morpho.flashLoan(address(usdg), flashAmount, abi.encode(msg.sender, tokenId, repayAmount, key, swapCalldata));

        uint256 profit = usdg.balanceOf(address(this));
        if (profit != 0) usdg.safeTransfer(msg.sender, profit);
    }

    /// @notice Morpho callback. Morpho pulls `assets` after this function returns.
    function onMorphoFlashLoan(
        uint256 assets,
        bytes calldata data
    ) external {
        if (msg.sender != address(morpho)) revert UnauthorizedMorpho(msg.sender);

        (, uint256 tokenId, uint256 repayAmount, PoolKey memory key, bytes memory swapCalldata) =
            abi.decode(data, (address, uint256, uint256, PoolKey, bytes));

        usdg.forceApprove(address(market), assets);
        market.liquidate(tokenId, repayAmount, 0, 0, address(this));
        usdg.forceApprove(address(market), 0);

        _swap(key, swapCalldata);
        _requireNoResidual(key.currency0);
        _requireNoResidual(key.currency1);
        if (address(this).balance != 0) revert ResidualBalance(address(0), address(this).balance);

        usdg.forceApprove(address(morpho), assets);
    }

    function _flashAmount(
        PoolKey memory key,
        uint256 repayAmount
    ) private view returns (uint256) {
        uint256 protocolFeeBps = market.policy().termsOf(key.toId()).liquidatorBonusBps / 10;
        return repayAmount * (BPS + protocolFeeBps) / BPS;
    }

    function _swap(
        PoolKey memory key,
        bytes memory swapCalldata
    ) private {
        uint256 nativeValue = _pushCurrency(key.currency0) + _pushCurrency(key.currency1);

        (bool ok, bytes memory reason) = universalRouter.call{value: nativeValue}(swapCalldata);
        if (!ok) revert SwapFailed(reason);
    }

    function _pushCurrency(
        Currency currency
    ) private returns (uint256 nativeValue) {
        address token = Currency.unwrap(currency);
        if (token == address(usdg)) return 0;
        if (token == address(0)) {
            return address(this).balance;
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance != 0) IERC20(token).safeTransfer(universalRouter, balance);
    }

    function _requireNoResidual(
        Currency currency
    ) private view {
        address token = Currency.unwrap(currency);
        if (token == address(0)) token = RobinhoodChain.WETH;
        if (token == address(usdg)) return;

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance != 0) revert ResidualBalance(token, balance);
    }
}
