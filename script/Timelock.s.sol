// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Sends one owner call of a market or the policy through the `TimelockController` that
///         owns them (script/Deploy.s.sol).
/// @dev An operation is the call itself: `TARGET`, `CALLDATA`, and optionally `VALUE`, `SALT` and
///      `PREDECESSOR`. The same variables name the same operation across the runs, so a
///      schedule is executed or cancelled by repeating it with another `--sig`:
///
///        TIMELOCK=0x… TARGET=<policy> CALLDATA=$(cast calldata "acceptOwnership()") \
///            forge script script/Timelock.s.sol --sig "schedule()" --rpc-url robinhood --broadcast
///        … the same, `--sig "execute()"`, once the delay has passed
///
///      `schedule()` and `cancel()` are the proposer's; `execute()` is the executor's.
///      `SALT` tells two identical calls apart, for instance the same `pause()` scheduled twice.
///
///      An upgrade crosses two queues, the timelock's and the market's own (FAR-21). With the
///      replacement from `Upgrade.s.sol --sig "deployReplacement()"`:
///        1. schedule `scheduleUpgrade(implementation)` on the proxy, and wait the timelock delay;
///        2. execute it, which starts the market's `TIMELOCK_DELAY`;
///        3. schedule `upgradeToAndCall(implementation, 0x)`, and execute it once both delays have
///           passed. It can also be queued together with step 1, with step 1's id as
///           `PREDECESSOR`: the timelock then holds it until step 1 has run, and the market until
///           its own `eta`. `Upgrade.s.sol --sig "execute()"` cannot be used here: it calls
///           the proxy as its owner, and the owner is now the timelock.
contract Timelock is Script {
    error NotReady(bytes32 id, uint256 readyAt, uint256 nowIs);
    error NotPending(bytes32 id);

    struct Operation {
        TimelockController timelock;
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;
        bytes32 salt;
        bytes32 id;
    }

    /// @notice Queues the operation for the timelock's minimum delay, or `OPERATION_DELAY` if longer.
    /// @return id The operation id.
    /// @return readyAt The earliest `block.timestamp` it can execute, as the simulation saw it.
    function schedule() external returns (bytes32 id, uint256 readyAt) {
        Operation memory op = _operation();
        uint256 delay = vm.envOr("OPERATION_DELAY", op.timelock.getMinDelay());

        vm.startBroadcast();
        op.timelock.schedule(op.target, op.value, op.data, op.predecessor, op.salt, delay);
        vm.stopBroadcast();

        id = op.id;
        readyAt = op.timelock.getTimestamp(id);
        _log(op);
        console2.log("Executable from (unix time, simulated)", readyAt);
    }

    /// @notice Executes the operation once its delay has passed.
    function execute() external {
        Operation memory op = _operation();
        uint256 readyAt = op.timelock.getTimestamp(op.id);
        if (!op.timelock.isOperationPending(op.id)) revert NotPending(op.id);
        if (!op.timelock.isOperationReady(op.id)) revert NotReady(op.id, readyAt, block.timestamp);

        vm.startBroadcast();
        op.timelock.execute{value: op.value}(op.target, op.value, op.data, op.predecessor, op.salt);
        vm.stopBroadcast();

        _log(op);
        console2.log("Executed");
    }

    /// @notice Withdraws the operation before it executes.
    function cancel() external {
        Operation memory op = _operation();
        if (!op.timelock.isOperationPending(op.id)) revert NotPending(op.id);

        vm.startBroadcast();
        op.timelock.cancel(op.id);
        vm.stopBroadcast();

        _log(op);
        console2.log("Cancelled");
    }

    function _operation() private view returns (Operation memory op) {
        op.timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        op.target = vm.envAddress("TARGET");
        op.value = vm.envOr("VALUE", uint256(0));
        op.data = vm.envBytes("CALLDATA");
        op.predecessor = vm.envOr("PREDECESSOR", bytes32(0));
        op.salt = vm.envOr("SALT", bytes32(0));
        op.id = op.timelock.hashOperation(op.target, op.value, op.data, op.predecessor, op.salt);
    }

    function _log(
        Operation memory op
    ) private pure {
        console2.log("Timelock", address(op.timelock));
        console2.log("Target", op.target);
        console2.log("Calldata");
        console2.logBytes(op.data);
        console2.log("Operation id");
        console2.logBytes32(op.id);
    }
}
