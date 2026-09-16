// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CollateralPolicy} from "../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../src/FarmentaMarket.sol";
import {InterestRateModel} from "../src/InterestRateModel.sol";
import {PositionValuer} from "../src/PositionValuer.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {RobinhoodChain} from "../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../src/interfaces/ICollateralPolicy.sol";

/// @notice Deploys the shared UUPS implementation and its Blue-chip and Meme proxies.
/// @dev Environment values override Robinhood mainnet defaults, keeping the release path
///      usable on a fork or a future chain without source edits. `DEPLOYER` signs the
///      initial policy configuration; when it differs from `OWNER`, the script begins the
///      policy's two-step ownership transfer and the designated owner must accept it.
contract Deploy is Script {
    struct Deployment {
        address priceOracle;
        address interestRateModel;
        address positionValuer;
        address collateralPolicy;
        address implementation;
        address blueChipProxy;
        address memeProxy;
        address owner;
    }

    struct Config {
        address deployer;
        address positionManager;
        address stateView;
        address usdg;
        address weth;
        address ethUsdFeed;
        address usdgUsdFeed;
        uint8 usdgDecimals;
        uint8 wethDecimals;
        string outputPath;
    }

    function run() external returns (Deployment memory deployment) {
        Config memory config = _config();
        address owner = vm.envAddress("OWNER");

        vm.startBroadcast(config.deployer);

        CollateralPolicy policy = new CollateralPolicy(Currency.wrap(config.usdg), config.deployer);
        policy.setTokenConfig(
            Currency.wrap(config.usdg), true, ICollateralPolicy.Tier.BLUE_CHIP, config.usdgDecimals, config.usdgUsdFeed
        );
        policy.setTokenConfig(
            Currency.wrap(config.weth), true, ICollateralPolicy.Tier.BLUE_CHIP, config.wethDecimals, config.ethUsdFeed
        );
        policy.setTokenConfig(
            Currency.wrap(address(0)), true, ICollateralPolicy.Tier.BLUE_CHIP, config.wethDecimals, config.ethUsdFeed
        );
        if (config.deployer != owner) policy.transferOwnership(owner);

        PriceOracle oracle = new PriceOracle(policy);
        InterestRateModel rateModel = new InterestRateModel();
        PositionValuer valuer =
            new PositionValuer(IPositionManager(payable(config.positionManager)), IStateView(config.stateView), oracle);
        FarmentaMarket implementation =
            new FarmentaMarket(IPositionManager(payable(config.positionManager)), policy, valuer, oracle, rateModel);
        ERC1967Proxy blueChipProxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                FarmentaMarket.initialize,
                (IERC20(config.usdg), "Farmenta USDG Blue-chip", "fUSDG-BC", ICollateralPolicy.Tier.BLUE_CHIP, owner)
            )
        );
        ERC1967Proxy memeProxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                FarmentaMarket.initialize,
                (IERC20(config.usdg), "Farmenta USDG Meme", "fUSDG-M", ICollateralPolicy.Tier.MEME, owner)
            )
        );
        vm.stopBroadcast();

        deployment = Deployment({
            priceOracle: address(oracle),
            interestRateModel: address(rateModel),
            positionValuer: address(valuer),
            collateralPolicy: address(policy),
            implementation: address(implementation),
            blueChipProxy: address(blueChipProxy),
            memeProxy: address(memeProxy),
            owner: owner
        });
        _writeDeployment(deployment, config.outputPath);
    }

    function _config() private view returns (Config memory config) {
        config.deployer = vm.envAddress("DEPLOYER");
        config.positionManager = vm.envOr("POSITION_MANAGER", RobinhoodChain.POSITION_MANAGER);
        config.stateView = vm.envOr("STATE_VIEW", RobinhoodChain.STATE_VIEW);
        config.usdg = vm.envOr("USDG", RobinhoodChain.USDG);
        config.weth = vm.envOr("WETH", RobinhoodChain.WETH);
        config.ethUsdFeed = vm.envOr("CHAINLINK_ETH_USD", RobinhoodChain.CHAINLINK_ETH_USD);
        config.usdgUsdFeed = vm.envOr("CHAINLINK_USDG_USD", RobinhoodChain.CHAINLINK_USDG_USD);
        config.usdgDecimals = uint8(vm.envOr("USDG_DECIMALS", uint256(RobinhoodChain.USDG_DECIMALS)));
        config.wethDecimals = uint8(vm.envOr("WETH_DECIMALS", uint256(RobinhoodChain.WETH_DECIMALS)));
        config.outputPath = vm.envOr("DEPLOYMENT_OUT", string("deployments/farmenta.json"));
    }

    function _writeDeployment(
        Deployment memory deployment,
        string memory outputPath
    ) private {
        string memory json = "farmenta";
        json = vm.serializeAddress(json, "priceOracle", deployment.priceOracle);
        json = vm.serializeAddress(json, "interestRateModel", deployment.interestRateModel);
        json = vm.serializeAddress(json, "positionValuer", deployment.positionValuer);
        json = vm.serializeAddress(json, "collateralPolicy", deployment.collateralPolicy);
        json = vm.serializeAddress(json, "implementation", deployment.implementation);
        json = vm.serializeAddress(json, "blueChipProxy", deployment.blueChipProxy);
        json = vm.serializeAddress(json, "memeProxy", deployment.memeProxy);
        json = vm.serializeAddress(json, "owner", deployment.owner);

        console2.log("PriceOracle", deployment.priceOracle);
        console2.log("InterestRateModel", deployment.interestRateModel);
        console2.log("PositionValuer", deployment.positionValuer);
        console2.log("CollateralPolicy", deployment.collateralPolicy);
        console2.log("FarmentaMarket implementation", deployment.implementation);
        console2.log("Blue-chip proxy", deployment.blueChipProxy);
        console2.log("Meme proxy", deployment.memeProxy);
        console2.log("Market owner", deployment.owner);
        console2.log("CollateralPolicy owner target", deployment.owner);
        vm.writeJson(json, outputPath);
        console2.log("Farmenta deployment written to", outputPath);
    }
}
