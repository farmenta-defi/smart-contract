// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MarketLedger} from "./MarketLedger.sol";

/// @title MarketUpgrade
/// @notice Linked execution for the market's upgrade timelock (ARCHITECTURE §4.1, FAR-21): the
///         queue an implementation waits in before `_authorizeUpgrade` lets it through.
/// @dev Runs by delegatecall, like `MarketDebt`: the market's storage, the market's address, so
///      the events are the market's. The market keeps the wrappers, and `onlyOwner` with them
///      (§4.1 v0.33). Nothing here checks the caller.
library MarketUpgrade {
    /// @notice An upgrade was scheduled: `newImplementation` can be installed from `eta` on.
    event UpgradeScheduled(address indexed newImplementation, uint256 eta);

    /// @notice The scheduled upgrade was withdrawn before it was installed.
    event UpgradeCancelled(address indexed newImplementation);

    error ZeroAddress();
    error UpgradeAlreadyScheduled(address implementation);
    error NoUpgradeScheduled();
    error UpgradeNotScheduled(address implementation);
    error UpgradeNotReady(address implementation, uint256 eta);

    /// @notice Queues `newImplementation`, installable `delay` from now at the earliest.
    /// @dev One upgrade waits at a time. A second schedule is refused until the first is cancelled
    ///      or installed, so every schedule ends in exactly one event: `UpgradeCancelled`, or
    ///      ERC-1967's `Upgraded`. Cancelling and scheduling again starts a full delay over, so no
    ///      sequence of calls brings an eta forward.
    function schedule(
        address newImplementation,
        uint256 delay
    ) external {
        if (newImplementation == address(0)) revert ZeroAddress();

        MarketLedger.Layout storage $ = MarketLedger.layout();
        if ($.pendingImplementation != address(0)) revert UpgradeAlreadyScheduled($.pendingImplementation);

        uint256 eta = block.timestamp + delay;
        $.pendingImplementation = newImplementation;
        $.upgradeEta = uint64(eta);
        emit UpgradeScheduled(newImplementation, eta);
    }

    /// @notice Withdraws the scheduled upgrade.
    function cancel() external {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        address pending = $.pendingImplementation;
        if (pending == address(0)) revert NoUpgradeScheduled();

        delete $.pendingImplementation;
        delete $.upgradeEta;
        emit UpgradeCancelled(pending);
    }

    /// @notice Lets `newImplementation` through if it is the one scheduled and its eta has come,
    ///         and spends the schedule.
    /// @dev Spent, so installing the same implementation a second time takes a new schedule and a
    ///      new delay.
    function spend(
        address newImplementation
    ) external {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        (address pending, uint256 eta) = ($.pendingImplementation, $.upgradeEta);
        if (pending == address(0) || newImplementation != pending) revert UpgradeNotScheduled(newImplementation);
        if (block.timestamp < eta) revert UpgradeNotReady(newImplementation, eta);

        delete $.pendingImplementation;
        delete $.upgradeEta;
    }
}
