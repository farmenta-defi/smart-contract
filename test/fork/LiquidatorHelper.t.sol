// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IFlashLoanMorpho, ILiquidationMarket, LiquidatorHelper} from "../../src/periphery/LiquidatorHelper.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

contract LiquidatorHelperForkTest is MarketForkTest {
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;
    address internal lender = address(0x1E4DE2);
    address internal keeper = address(0xBEEF17);
    uint256 internal tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
    address internal borrower;
    IERC20 internal usdg;
    LiquidatorHelper internal helper;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function setUp() public override {
        super.setUp();
        borrower = IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);
        usdg = IERC20(address(market.asset()));
        helper = new LiquidatorHelper(
            ILiquidationMarket(address(market)),
            IFlashLoanMorpho(RobinhoodChain.MORPHO_BLUE),
            RobinhoodChain.UNIVERSAL_ROUTER
        );
    }

    receive() external payable {}

    function test_partialLiquidationPushesBalanceAndPaysProfit() public {
        _open();
        _ageUntilUnhealthy();

        uint256 repayAmount = market.debtOf(tokenId);
        PoolKey memory plain = Fixtures.liveRecorderPoolKeys()[1];
        vm.prank(keeper);
        helper.execute(tokenId, repayAmount, _route(plain, 0));

        _assertEmpty();
        assertEq(IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId), address(market));
    }

    function test_fullLiquidationPushesBalanceAndBurnsPosition() public {
        _open();
        _dropEthPrice(1200e18);

        PoolKey memory plain = Fixtures.liveRecorderPoolKeys()[1];
        uint256 budget = market.debtOf(tokenId) * 2;
        vm.prank(keeper);
        helper.execute(tokenId, budget, _route(plain, 0));

        _assertEmpty();
        vm.expectRevert();
        IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);
    }

    function test_donatedFeesAreCoveredByTheBorrowBudget() public {
        _open();
        _donate(0.1 ether);
        _ageUntilUnhealthy();

        vm.prank(keeper);
        helper.execute(tokenId, market.debtOf(tokenId), _route(_keyOf(tokenId), 0));
        _assertEmpty();
    }

    function test_donatedFeesAtCloseFactorAreRejectedAsUnderfunded() public {
        _open();
        _donate(0.1 ether);
        _ageUntilUnhealthy();

        uint256 debt = market.debtOf(tokenId);
        address probe = address(0xCAFE17);
        deal(address(usdg), probe, 1_000_000e6);
        vm.startPrank(probe);
        usdg.approve(address(market), type(uint256).max);
        vm.expectRevert();
        market.liquidate(tokenId, debt / 2, 0, 0, probe);
        vm.stopPrank();
    }

    function test_zeroRepaymentBudgetRevertsBeforeFlashLoan() public {
        vm.prank(keeper);
        vm.expectRevert(LiquidatorHelper.ZeroRepayAmount.selector);
        helper.execute(tokenId, 0, "");
    }

    function test_repayBelowCloseFactorStillCoversProtocolFee() public {
        _open();
        _ageUntilUnhealthy();
        uint256 repayAmount = market.debtOf(tokenId) / 4;
        vm.prank(keeper);
        helper.execute(tokenId, repayAmount, _route(Fixtures.liveRecorderPoolKeys()[1], 0));
        assertGt(usdg.balanceOf(keeper), 0, "profit did not reach keeper");
        _assertEmpty();
    }

    function test_onlyMorphoCanInvokeTheCallback() public {
        vm.expectRevert(abi.encodeWithSelector(LiquidatorHelper.UnauthorizedMorpho.selector, address(this)));
        helper.onMorphoFlashLoan(1, "");
    }

    function test_erc20CollateralIsPushedToTheRouter() public {
        tokenId = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        borrower = IERC721(RobinhoodChain.POSITION_MANAGER).ownerOf(tokenId);
        _openWith(10_000e6);
        _ageUntilUnhealthy();

        uint256 repayAmount = market.debtOf(tokenId);
        vm.prank(keeper);
        helper.execute(tokenId, repayAmount, _route(_keyOf(tokenId), 0));

        _assertEmpty();
        assertEq(IERC20(RobinhoodChain.WETH).balanceOf(RobinhoodChain.UNIVERSAL_ROUTER), 0);
    }

    function test_unreachableMinOutReverts() public {
        _open();
        _ageUntilUnhealthy();
        uint256 debt = market.debtOf(tokenId);
        vm.prank(keeper);
        vm.expectRevert();
        helper.execute(tokenId, debt, _route(Fixtures.liveRecorderPoolKeys()[1], type(uint128).max));
    }

    function test_saleThatCannotRepayTheFlashLoanRevertsAtomically() public {
        _open();
        _ageUntilUnhealthy();
        uint256 debt = market.debtOf(tokenId);
        vm.prank(keeper);
        vm.expectRevert();
        helper.execute(tokenId, debt, _route(Fixtures.liveRecorderPoolKeys()[1], type(uint128).max));
        assertEq(market.debtOf(tokenId), debt, "failed sale changed debt");
        _assertEmpty();
    }

    function test_healthyPositionRevertsThroughMarket() public {
        _open();
        uint256 debt = market.debtOf(tokenId);
        vm.prank(keeper);
        vm.expectRevert();
        helper.execute(tokenId, debt, _route(Fixtures.liveRecorderPoolKeys()[1], 0));
    }

    function test_marketAllowanceIsClearedAfterExecution() public {
        _open();
        _ageUntilUnhealthy();
        uint256 debt = market.debtOf(tokenId);
        vm.prank(keeper);
        helper.execute(tokenId, debt, _route(Fixtures.liveRecorderPoolKeys()[1], 0));
        assertEq(usdg.allowance(address(helper), address(market)), 0);
    }

    function test_routeReturningUnspentEthToHelperReverts() public {
        _open();
        _ageUntilUnhealthy();
        uint256 debt = market.debtOf(tokenId);
        uint256 seizedEth = _previewOut0(debt);
        bytes memory route = _routeWithSweep(Fixtures.liveRecorderPoolKeys()[1], seizedEth * 95 / 100);

        vm.prank(keeper);
        vm.expectRevert();
        helper.execute(tokenId, debt, route);
        assertEq(market.debtOf(tokenId), debt, "failed liquidation changed debt");
        _assertEmpty();
    }

    function _open() private {
        _openWith(300e6);
    }

    function _openWith(
        uint256 lenderCash
    ) private {
        _listPoolOf(tokenId, 50e18);
        vm.startPrank(borrower);
        IERC721(RobinhoodChain.POSITION_MANAGER).approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(usdg), lender, lenderCash);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(lenderCash, lender);
        vm.stopPrank();

        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
    }

    function _ageUntilUnhealthy() private {
        for (uint256 i; i < 4000; ++i) {
            if (lens.healthFactor(tokenId) < 1e18) return;
            vm.warp(block.timestamp + 1 days);
            market.accrue();
        }
        revert("fixture did not become unhealthy");
    }

    function _dropEthPrice(
        uint256 price
    ) private {
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), price, 18);
        oracle.set(Currency.wrap(RobinhoodChain.WETH), price, 18);
        market.accrue();
    }

    function _donate(
        uint256 ethAmount
    ) private {
        PoolKey memory key = _keyOf(tokenId);
        uint256 poolLiquidity = stateView.getLiquidity(key.toId());
        uint256 positionLiquidity = positionManager.getPositionLiquidity(tokenId);
        PoolDonateTest donor = new PoolDonateTest(poolManager);
        uint256 donation = ethAmount * poolLiquidity / positionLiquidity;
        vm.deal(address(this), donation);
        donor.donate{value: donation}(key, donation, 0, "");
    }

    function _route(
        PoolKey memory key,
        uint128 minOut
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x0b), uint8(0x06), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key.currency0, CONTRACT_BALANCE, false);
        params[1] = abi.encode(
            ExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0, amountOutMinimum: minOut, minHopPriceX36: 0, hookData: ""
            })
        );
        params[2] = abi.encode(key.currency1, uint256(minOut));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        return
            abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(uint8(0x10)), inputs, block.timestamp + 1 hours));
    }

    function _routeWithSweep(
        PoolKey memory key,
        uint256 amountIn
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(0x0b), uint8(0x06), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key.currency0, amountIn, false);
        params[1] = abi.encode(
            ExactInputSingleParams({
                poolKey: key, zeroForOne: true, amountIn: 0, amountOutMinimum: 0, minHopPriceX36: 0, hookData: ""
            })
        );
        params[2] = abi.encode(key.currency1, uint256(0));

        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(address(0), address(helper), uint256(0));
        return abi.encodeCall(
            IUniversalRouter.execute, (abi.encodePacked(uint8(0x10), uint8(0x04)), inputs, block.timestamp + 1 hours)
        );
    }

    function _previewOut0(
        uint256 repayAmount
    ) private returns (uint256 out0) {
        uint256 snap = vm.snapshotState();
        address probe = address(0x9807BE);
        deal(address(usdg), probe, 1_000_000e6);
        vm.startPrank(probe);
        usdg.approve(address(market), type(uint256).max);
        (, out0,,) = market.liquidate(tokenId, repayAmount, 0, 0, probe);
        vm.stopPrank();
        vm.revertToState(snap);
    }

    function _assertEmpty() private view {
        assertEq(usdg.balanceOf(address(helper)), 0, "USDG remains");
        assertEq(IERC20(RobinhoodChain.WETH).balanceOf(address(helper)), 0, "WETH remains");
        assertEq(address(helper).balance, 0, "ETH remains");
    }
}
