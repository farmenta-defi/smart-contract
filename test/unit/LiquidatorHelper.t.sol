// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Test} from "forge-std/Test.sol";

import {IFlashLoanMorpho, ILiquidationMarket, LiquidatorHelper} from "../../src/periphery/LiquidatorHelper.sol";

contract LiquidatorHelperHarness is LiquidatorHelper {
    constructor(
        IERC20 weth_
    )
        LiquidatorHelper(ILiquidationMarket(address(0x1001)), IFlashLoanMorpho(address(0x1002)), address(0x1003), weth_)
    {}

    function checkNoNativeResidual() external view {
        _requireNoResidual(Currency.wrap(address(0)));
    }
}

contract LiquidatorHelperTest is Test {
    address internal constant WETH = address(0x2001);
    address internal constant USDG = address(0x2002);
    address internal constant POSITION_MANAGER = address(0x2003);

    function setUp() public {
        vm.mockCall(
            address(0x1001), abi.encodeWithSelector(ILiquidationMarket.asset.selector), abi.encode(IERC20(USDG))
        );
        vm.mockCall(
            address(0x1001),
            abi.encodeWithSelector(ILiquidationMarket.positionManager.selector),
            abi.encode(IPositionManager(POSITION_MANAGER))
        );
    }

    function test_constructorStoresConfiguredWethAndChecksNativeResidualAtThatAddress() public {
        LiquidatorHelperHarness helper = new LiquidatorHelperHarness(IERC20(WETH));
        assertEq(address(helper.weth()), WETH);

        vm.mockCall(WETH, abi.encodeWithSelector(IERC20.balanceOf.selector, address(helper)), abi.encode(1));
        vm.expectRevert(abi.encodeWithSelector(LiquidatorHelper.ResidualBalance.selector, WETH, 1));
        helper.checkNoNativeResidual();
    }

    function test_RevertWhenWethIsAddressZero() public {
        vm.expectRevert(LiquidatorHelper.ZeroWeth.selector);
        new LiquidatorHelperHarness(IERC20(address(0)));
    }
}
