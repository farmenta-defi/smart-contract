// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {InterestRateModel} from "../../src/InterestRateModel.sol";
import {PositionValuer} from "../../src/PositionValuer.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {PositionMinter} from "./PositionMinter.sol";

/// @title MarketForkTest
/// @notice A real market over real Uniswap state, for every fork suite that drives
///         `FarmentaMarket`.
/// @dev Policy, valuer and a Blue-chip proxy are wired the way a deployment wires them. The
///      price feed is the one substitute, pinned to the fixture pool's own spot price, so
///      the valuation a test sees is the one the chain would give.
abstract contract MarketForkTest is PositionMinter {
    /// @dev ETH price implied by the fixture pool's own spot price at the pinned block, so
    ///      oracle and pool agree and the valuation is the one the chain would give.
    uint256 internal constant ETH_AT_POOL_SPOT = 2520.1324440246868e18;
    uint256 internal constant ONE_USD = 1e18;

    address internal owner = address(0xA11CE);

    MockPriceOracle internal oracle;
    PositionValuer internal valuer;
    CollateralPolicy internal policy;
    FarmentaMarket internal market;
    InterestRateModel internal interestRateModel;
    IERC721 internal nft;

    function setUp() public virtual override {
        super.setUp();

        oracle = new MockPriceOracle();
        oracle.set(Currency.wrap(RobinhoodChain.NATIVE), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT, 18);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), ONE_USD, RobinhoodChain.USDG_DECIMALS);

        valuer = new PositionValuer(positionManager, stateView, oracle);
        policy = new CollateralPolicy(Currency.wrap(RobinhoodChain.USDG), owner);

        vm.startPrank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.USDG), true, ICollateralPolicy.Tier.BLUE_CHIP, 6, address(1));
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.WETH), true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(1)
        );
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(1)
        );
        vm.stopPrank();

        interestRateModel = new InterestRateModel();
        market = _deployMarket(ICollateralPolicy.Tier.BLUE_CHIP);
        nft = IERC721(RobinhoodChain.POSITION_MANAGER);
    }

    function _keyOf(
        uint256 tokenId
    ) internal view returns (PoolKey memory key) {
        (key,) = positionManager.getPoolAndPositionInfo(tokenId);
    }

    /// @dev The tick the oracle implies, snapped down onto the pool's spacing. Ranges are
    ///      placed against this rather than the pool's own tick because the valuer decides
    ///      in or out of range at the oracle price (§5.1).
    function _alignedOracleTick(
        int24 spacing
    ) internal pure returns (int24) {
        int24 tick = TickMath.getTickAtSqrtPrice(
            PriceMath.derivedSqrtPriceX96(ETH_AT_POOL_SPOT, ONE_USD, 18, RobinhoodChain.USDG_DECIMALS)
        );
        // Dividing before multiplying is the point: it snaps the tick down onto the spacing.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
        return aligned;
    }

    function _listPoolOf(
        uint256 tokenId,
        uint128 minPositionUsd
    ) internal {
        _listPoolOf(tokenId, minPositionUsd, 0);
    }

    function _listPoolOf(
        uint256 tokenId,
        uint128 minPositionUsd,
        uint16 removeHaircutBps
    ) internal {
        _listPool(_keyOf(tokenId), minPositionUsd, removeHaircutBps);
    }

    /// @dev The key is taken as an argument, never read inside the prank. Reading it there
    ///      would be an external call, which spends the prank and leaves `list` to be called
    ///      by this test contract, which is not the owner.
    function _listPool(
        PoolKey memory key,
        uint128 minPositionUsd,
        uint16 removeHaircutBps
    ) internal {
        TierPresets.Preset memory preset = TierPresets.blueChip();

        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: removeHaircutBps,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: minPositionUsd
            })
        );
    }

    function _deployMarket(
        ICollateralPolicy.Tier tier_
    ) internal returns (FarmentaMarket) {
        FarmentaMarket implementation = new FarmentaMarket(positionManager, policy, valuer, oracle, interestRateModel);
        return FarmentaMarket(
            payable(address(
                    new ERC1967Proxy(
                        address(implementation),
                        abi.encodeCall(
                            FarmentaMarket.initialize,
                            (IERC20(RobinhoodChain.USDG), "Farmenta USDG", "fUSDG", tier_, owner)
                        )
                    )
                ))
        );
    }
}
