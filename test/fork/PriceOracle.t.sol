// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/// @notice Exercises the production oracle against the pinned Chainlink feeds.
contract PriceOracleForkTest is ForkTest {
    address internal constant OWNER = address(0xA11CE);

    CollateralPolicy internal policy;
    PriceOracle internal oracle;

    function setUp() public override {
        super.setUp();
        policy = new CollateralPolicy(Currency.wrap(RobinhoodChain.USDG), OWNER);

        vm.startPrank(OWNER);
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.USDG),
            true,
            ICollateralPolicy.Tier.BLUE_CHIP,
            6,
            RobinhoodChain.CHAINLINK_USDG_USD
        );
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.WETH),
            true,
            ICollateralPolicy.Tier.BLUE_CHIP,
            18,
            RobinhoodChain.CHAINLINK_ETH_USD
        );
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.NATIVE),
            true,
            ICollateralPolicy.Tier.BLUE_CHIP,
            18,
            RobinhoodChain.CHAINLINK_ETH_USD
        );
        vm.stopPrank();

        oracle = new PriceOracle(policy);
    }

    function test_usdgPriceMatchesTheDirectFeedRead() public view {
        (, int256 answer,,,) = IAggregatorV3(RobinhoodChain.CHAINLINK_USDG_USD).latestRoundData();
        assertGt(answer, 0, "USDG feed answer must be positive");
        assertEq(oracle.price(Currency.wrap(RobinhoodChain.USDG)), uint256(answer) * 1e10);
    }

    function test_nativeEthAndWethHaveTheSamePrice() public view {
        assertEq(oracle.price(Currency.wrap(RobinhoodChain.NATIVE)), oracle.price(Currency.wrap(RobinhoodChain.WETH)));
    }

    function test_realOracleValuesAllFivePositionFixtures() public {
        MockPriceOracle mock = new MockPriceOracle();
        _copyPricesTo(mock);

        PositionValuer productionValuer = new PositionValuer(positionManager, stateView, oracle);
        PositionValuer referenceValuer = new PositionValuer(positionManager, stateView, mock);

        _assertSameValuation(productionValuer, referenceValuer, Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        _assertSameValuation(productionValuer, referenceValuer, Fixtures.POS_ETH_USDG_IN_RANGE);
        _assertSameValuation(productionValuer, referenceValuer, Fixtures.POS_ETH_USDG_ABOVE_RANGE);
        _assertSameValuation(productionValuer, referenceValuer, Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);
        _assertSameValuation(productionValuer, referenceValuer, Fixtures.POS_WETH_USDG_ABOVE_RANGE);
    }

    function _copyPricesTo(
        MockPriceOracle mock
    ) internal {
        mock.set(Currency.wrap(RobinhoodChain.NATIVE), oracle.price(Currency.wrap(RobinhoodChain.NATIVE)), 18);
        mock.set(Currency.wrap(RobinhoodChain.WETH), oracle.price(Currency.wrap(RobinhoodChain.WETH)), 18);
        mock.set(Currency.wrap(RobinhoodChain.USDG), oracle.price(Currency.wrap(RobinhoodChain.USDG)), 6);
    }

    function _assertSameValuation(
        PositionValuer productionValuer,
        PositionValuer referenceValuer,
        uint256 tokenId
    ) internal view {
        IPositionValuer.Valuation memory actual = productionValuer.value(tokenId);
        IPositionValuer.Valuation memory expected = referenceValuer.value(tokenId);

        assertEq(actual.liquidity, expected.liquidity, "liquidity");
        assertEq(actual.amount0, expected.amount0, "amount0");
        assertEq(actual.amount1, expected.amount1, "amount1");
        assertEq(actual.fees0, expected.fees0, "fees0");
        assertEq(actual.fees1, expected.fees1, "fees1");
        assertEq(actual.principalUsd, expected.principalUsd, "principalUsd");
        assertEq(actual.feesUsd, expected.feesUsd, "feesUsd");
        assertEq(actual.spotDeviationBps, expected.spotDeviationBps, "spotDeviationBps");
    }
}
