// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockPyth} from "../mocks/MockPyth.sol";

/// @notice Unit tests for Chainlink normalization and policy-backed token metadata.
contract PriceOracleTest is Test {
    Currency internal constant USDG = Currency.wrap(address(0x1001));
    Currency internal constant WETH = Currency.wrap(address(0x1002));
    Currency internal constant NATIVE = Currency.wrap(address(0));
    Currency internal constant UNKNOWN = Currency.wrap(address(0x1003));

    address internal constant OWNER = address(0xA11CE);
    bytes32 internal constant PYTH_ETH_USD_PRICE_ID =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    CollateralPolicy internal policy;
    PriceOracle internal oracle;
    MockAggregatorV3 internal ethUsd;
    MockAggregatorV3 internal usdgUsd;
    MockPyth internal pyth;

    function setUp() public {
        vm.warp(26 hours);
        policy = new CollateralPolicy(USDG, OWNER);
        ethUsd = new MockAggregatorV3(8);
        usdgUsd = new MockAggregatorV3(8);
        ethUsd.setAnswer(2520e8, block.timestamp);
        usdgUsd.setAnswer(1e8, block.timestamp);
        pyth = new MockPyth();
        pyth.setPrice(PYTH_ETH_USD_PRICE_ID, 2520e8, -8, block.timestamp);

        vm.startPrank(OWNER);
        policy.setTokenConfig(USDG, true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(usdgUsd));
        policy.setTokenConfig(WETH, true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(ethUsd));
        policy.setTokenConfig(NATIVE, true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(ethUsd));
        vm.stopPrank();

        oracle = new PriceOracle(policy, pyth);
    }

    function test_priceNormalizesFeedDecimalsToUsd1e18() public view {
        assertEq(oracle.price(USDG), 1e18);
        assertEq(oracle.price(WETH), 2520e18);
    }

    function test_nativeEthAndWethUseTheSameFeed() public view {
        assertEq(oracle.price(NATIVE), oracle.price(WETH));
    }

    function test_priceForLiquidationMatchesPriceForMvp() public view {
        assertEq(oracle.priceForLiquidation(WETH), oracle.price(WETH));
    }

    function test_decimalsComeFromThePolicyListing() public view {
        assertEq(oracle.decimals(USDG), 6);
        assertEq(oracle.decimals(NATIVE), 18);
    }

    function test_priceAndDecimalsRemainAvailableAfterTokenIsDisabled() public {
        vm.prank(OWNER);
        policy.setTokenConfig(WETH, false, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(ethUsd));

        assertEq(oracle.price(WETH), 2520e18);
        assertEq(oracle.decimals(WETH), 18);
    }

    function test_priceAcceptsAFeedUpdatedTwentyFourHoursAgo() public {
        ethUsd.setAnswer(2520e8, block.timestamp - 24 hours);
        assertEq(oracle.price(WETH), 2520e18);
    }

    function test_priceRevertsForAFeedOlderThanTwentyFiveHours() public {
        ethUsd.setAnswer(2520e8, block.timestamp - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.StalePrice.selector, WETH, block.timestamp - 25 hours - 1));
        oracle.price(WETH);
    }

    function test_priceRevertsForZeroOrNegativeAnswers() public {
        ethUsd.setAnswer(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPrice.selector, WETH, int256(0)));
        oracle.price(WETH);

        ethUsd.setAnswer(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.InvalidPrice.selector, WETH, int256(-1)));
        oracle.price(WETH);
    }

    function test_unlistedTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.PriceFeedNotConfigured.selector, UNKNOWN));
        oracle.price(UNKNOWN);
    }

    function test_pythEthUsdReturnsFreshNormalizedPrice() public view {
        (uint256 price_, uint256 publishTime) = oracle.pythEthUsd();
        assertEq(price_, 2520e18);
        assertEq(publishTime, block.timestamp);
    }

    function test_pythEthUsdReturnsStalePriceForMarketToEvaluate() public {
        pyth.setPrice(PYTH_ETH_USD_PRICE_ID, 1e8, -8, block.timestamp - 10 minutes - 1);
        (uint256 price_, uint256 publishTime) = oracle.pythEthUsd();
        assertEq(price_, 1e18);
        assertEq(publishTime, block.timestamp - 10 minutes - 1);
    }

    function test_pythEthUsdReturnsFreshDeviationForMarketToEvaluate() public {
        pyth.setPrice(PYTH_ETH_USD_PRICE_ID, 2600e8, -8, block.timestamp);
        (uint256 price_,) = oracle.pythEthUsd();
        assertEq(price_, 2600e18);
    }

    function test_usdgPricePreservesA98CentDeviation() public {
        usdgUsd.setAnswer(0.98e8, block.timestamp);
        assertEq(oracle.price(USDG), 0.98e18);
    }

    function test_pythEthUsdIsIndependentOfTier() public view {
        (uint256 price_,) = oracle.pythEthUsd();
        assertEq(price_, 2520e18);
    }
}
