// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FarmentaMarket} from "../src/FarmentaMarket.sol";

/// @notice Deploys a replacement implementation and upgrades one FarmentaMarket proxy.
/// @dev Dependencies are read from the current implementation through the proxy, so the
///      upgrade script is chain-agnostic and cannot silently replace an immutable dependency.
contract Upgrade is Script {
    function run() external returns (address implementation) {
        FarmentaMarket proxy = FarmentaMarket(payable(vm.envAddress("PROXY")));
        bytes memory callData = vm.envOr("UPGRADE_CALLDATA", bytes(""));

        vm.startBroadcast();
        FarmentaMarket next = new FarmentaMarket(
            proxy.positionManager(), proxy.policy(), proxy.valuer(), proxy.oracle(), proxy.interestRateModel()
        );
        proxy.upgradeToAndCall(address(next), callData);
        vm.stopBroadcast();

        implementation = address(next);
        console2.log("FarmentaMarket implementation", implementation);
        console2.log("Upgraded proxy", address(proxy));
    }
}
