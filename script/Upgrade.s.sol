// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FarmentaMarket} from "../src/FarmentaMarket.sol";
import {ICollateralPolicy} from "../src/interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../src/interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../src/interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";

/// @notice Deploys a replacement implementation and upgrades one FarmentaMarket proxy.
/// @dev Each dependency defaults to the current implementation's immutable address. Set the
///      corresponding environment variable to intentionally replace one during an upgrade.
contract Upgrade is Script {
    function run() external returns (address implementation) {
        FarmentaMarket proxy = FarmentaMarket(payable(vm.envAddress("PROXY")));
        bytes memory callData = vm.envOr("UPGRADE_CALLDATA", bytes(""));
        address positionManager = vm.envOr("POSITION_MANAGER", address(proxy.positionManager()));
        address policy = vm.envOr("COLLATERAL_POLICY", address(proxy.policy()));
        address valuer = vm.envOr("POSITION_VALUER", address(proxy.valuer()));
        address oracle = vm.envOr("PRICE_ORACLE", address(proxy.oracle()));
        address interestRateModel = vm.envOr("INTEREST_RATE_MODEL", address(proxy.interestRateModel()));

        vm.startBroadcast();
        FarmentaMarket next = new FarmentaMarket(
            IPositionManager(payable(positionManager)),
            ICollateralPolicy(policy),
            IPositionValuer(valuer),
            IPriceOracle(oracle),
            IInterestRateModel(interestRateModel)
        );
        proxy.upgradeToAndCall(address(next), callData);
        vm.stopBroadcast();

        implementation = address(next);
        console2.log("FarmentaMarket implementation", implementation);
        console2.log("Upgraded proxy", address(proxy));
    }
}
