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

/// @notice Upgrades one FarmentaMarket proxy through its timelock (ARCHITECTURE §4.1, FAR-21).
/// @dev Two runs, `TIMELOCK_DELAY` apart, both broadcast by the proxy's owner:
///
///        FOUNDRY_PROFILE=deploy PROXY=0x… forge script script/Upgrade.s.sol --sig "schedule()" \
///            --rpc-url robinhood --broadcast
///        FOUNDRY_PROFILE=deploy PROXY=0x… forge script script/Upgrade.s.sol --sig "execute()" \
///            --rpc-url robinhood --broadcast
///
///      `deploy` is the profile that ships (foundry.toml). Scheduled from another profile, the
///      replacement is other bytecode than a reader builds from the same source, and its hash
///      matches nothing they can reproduce.
///
///      There is no `run()`: a script that picked the step itself would make the second run a
///      matter of timing, and an upgrade is the one transaction that should never be sent by
///      accident. `cancel()` withdraws a schedule, which is also what an expired one needs before
///      `schedule()` can run again.
///
///      `schedule()` deploys the replacement itself. Each dependency defaults to the address the
///      proxy's current implementation holds; set the matching environment variable to replace
///      one on purpose. `execute()` deploys nothing and installs what the proxy says is pending,
///      so what goes in is what was announced.
contract Upgrade is Script {
    error NothingScheduled(address proxy);
    error TooEarly(address implementation, uint256 eta, uint256 nowIs);
    error CodeChanged(address implementation, bytes32 scheduled, bytes32 found);
    error Expired(address implementation, uint256 expiredAt, uint256 nowIs);

    /// @notice Deploys the replacement implementation and schedules it.
    /// @return implementation The implementation deployed and scheduled.
    /// @return eta The earliest `block.timestamp` at which `execute()` can install it, as the
    ///         simulation saw it. The eta that binds is counted from the block the broadcast
    ///         lands in, a few seconds later: read it from `pendingUpgrade()` or from
    ///         `UpgradeScheduled`.
    function schedule() external returns (address implementation, uint256 eta) {
        FarmentaMarket proxy = _proxy();
        address positionManager = vm.envOr("POSITION_MANAGER", address(proxy.positionManager()));
        address policy = vm.envOr("COLLATERAL_POLICY", address(proxy.policy()));
        address valuer = vm.envOr("POSITION_VALUER", address(proxy.valuer()));
        address oracle = vm.envOr("PRICE_ORACLE", address(proxy.oracle()));
        address interestRateModel = vm.envOr("INTEREST_RATE_MODEL", address(proxy.interestRateModel()));

        vm.startBroadcast();
        implementation = address(
            new FarmentaMarket(
                IPositionManager(payable(positionManager)),
                ICollateralPolicy(policy),
                IPositionValuer(valuer),
                IPriceOracle(oracle),
                IInterestRateModel(interestRateModel)
            )
        );
        proxy.scheduleUpgrade(implementation);
        vm.stopBroadcast();

        (, eta) = proxy.pendingUpgrade();
        console2.log("Proxy", address(proxy));
        console2.log("Scheduled implementation", implementation);
        console2.log("Installable from (unix time, simulated)", eta);
        console2.log("Installable until (unix time, simulated)", eta + proxy.TIMELOCK_GRACE());
        console2.log("Code hash the schedule is held to");
        console2.logBytes32(proxy.pendingUpgradeCodehash());
        console2.log("The eta that binds is set by the mined block: read pendingUpgrade() on the proxy");
    }

    /// @notice Installs the implementation the proxy has pending, once its eta has come.
    /// @return implementation The implementation installed.
    /// @dev `UPGRADE_CALLDATA`, if set, is run by the new implementation in the same transaction.
    function execute() external returns (address implementation) {
        FarmentaMarket proxy = _proxy();
        uint256 eta;
        (implementation, eta) = proxy.pendingUpgrade();
        if (implementation == address(0)) revert NothingScheduled(address(proxy));
        if (block.timestamp < eta) revert TooEarly(implementation, eta, block.timestamp);
        uint256 expiredAt = eta + proxy.TIMELOCK_GRACE();
        if (block.timestamp > expiredAt) revert Expired(implementation, expiredAt, block.timestamp);
        bytes32 scheduled = proxy.pendingUpgradeCodehash();
        if (implementation.codehash != scheduled) {
            revert CodeChanged(implementation, scheduled, implementation.codehash);
        }

        bytes memory callData = vm.envOr("UPGRADE_CALLDATA", bytes(""));
        console2.log("Calldata the new implementation runs, in bytes", callData.length);
        if (callData.length != 0) console2.logBytes(callData);

        vm.startBroadcast();
        proxy.upgradeToAndCall(implementation, callData);
        vm.stopBroadcast();

        console2.log("Proxy", address(proxy));
        console2.log("Installed implementation", implementation);
    }

    /// @notice Withdraws the upgrade the proxy has pending.
    /// @return implementation The implementation that was scheduled.
    function cancel() external returns (address implementation) {
        FarmentaMarket proxy = _proxy();
        (implementation,) = proxy.pendingUpgrade();
        if (implementation == address(0)) revert NothingScheduled(address(proxy));

        vm.startBroadcast();
        proxy.cancelUpgrade();
        vm.stopBroadcast();

        console2.log("Proxy", address(proxy));
        console2.log("Cancelled implementation", implementation);
    }

    function _proxy() private view returns (FarmentaMarket) {
        return FarmentaMarket(payable(vm.envAddress("PROXY")));
    }
}
