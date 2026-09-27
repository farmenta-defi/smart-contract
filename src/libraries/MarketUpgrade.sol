// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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

    /// @notice The hash of the code `newImplementation` held when it was scheduled.
    event UpgradeCodeBound(address indexed newImplementation, bytes32 codehash);

    /// @notice The scheduled upgrade was withdrawn before it was installed.
    event UpgradeCancelled(address indexed newImplementation);

    error ZeroAddress();
    error UpgradeAlreadyScheduled(address implementation);
    error NoUpgradeScheduled();
    error UpgradeNotScheduled(address implementation);
    error UpgradeNotReady(address implementation, uint256 eta);
    error ImplementationHasNoCode(address implementation);
    error ImplementationCodeChanged(address implementation, bytes32 scheduled, bytes32 found);
    error ImplementationIsAPointer(address implementation);
    error UpgradeExpired(address implementation, uint256 expiredAt);

    /// @notice Queues `newImplementation`, installable `delay` from now at the earliest.
    /// @dev One upgrade waits at a time. A second schedule is refused until the first is cancelled
    ///      or installed, so every schedule ends in exactly one event: `UpgradeCancelled`, or
    ///      ERC-1967's `Upgraded`. Cancelling and scheduling again starts a full delay over, so no
    ///      sequence of calls brings an eta forward.
    ///
    ///      The schedule holds the hash of the code it was given, not the address alone. An
    ///      address can be scheduled before anything is deployed to it, and code created and
    ///      removed inside the scheduling transaction is gone again by its end (EIP-6780 still
    ///      lets a contract remove itself in the transaction that created it). Refusing an empty
    ///      address here stops the first; only `spend` comparing the hash stops the second.
    ///
    ///      Code that starts with 0xEF is refused too. No deployed contract starts with it
    ///      (EIP-3541); what does is the 23 bytes an account holds while it is delegated
    ///      (EIP-7702), which name an address and nothing else. Their hash would stay the same
    ///      while the account is pointed at other code, after the upgrade and without a schedule.
    ///      Checked here only: an account that holds code has no key to delegate with later.
    ///
    ///      What none of this can tell is code created in the installing transaction from code
    ///      that stood there before it. Code put back, installed and removed in one transaction
    ///      passes, and leaves the address free for other code afterwards. The sign is off chain:
    ///      the scheduled address holds no code during the delay.
    function schedule(
        address newImplementation,
        uint256 delay
    ) external {
        if (newImplementation == address(0)) revert ZeroAddress();
        if (newImplementation.code.length == 0) revert ImplementationHasNoCode(newImplementation);
        if (_firstByte(newImplementation) == 0xEF) revert ImplementationIsAPointer(newImplementation);

        MarketLedger.Layout storage $ = MarketLedger.layout();
        if ($.pendingImplementation != address(0)) revert UpgradeAlreadyScheduled($.pendingImplementation);

        uint256 eta = block.timestamp + delay;
        $.pendingImplementation = newImplementation;
        $.upgradeEta = SafeCast.toUint64(eta);
        bytes32 codehash = newImplementation.codehash;
        $.pendingCodehash = codehash;
        emit UpgradeScheduled(newImplementation, eta);
        emit UpgradeCodeBound(newImplementation, codehash);
    }

    /// @notice Withdraws the scheduled upgrade.
    function cancel() external {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        address pending = $.pendingImplementation;
        if (pending == address(0)) revert NoUpgradeScheduled();

        delete $.pendingImplementation;
        delete $.upgradeEta;
        delete $.pendingCodehash;
        emit UpgradeCancelled(pending);
    }

    /// @notice Lets `newImplementation` through if it is the one scheduled, its eta has come and
    ///         not gone by more than `grace`, and its code is the code that was scheduled, and
    ///         spends the schedule.
    /// @dev Spent, so installing the same implementation a second time takes a new schedule and a
    ///      new delay. A refusal spends nothing: the schedule stays as it was.
    ///
    ///      An expired schedule stays in the queue until it is cancelled, so it still ends in
    ///      exactly one event, and the next schedule is a new notice with a full delay.
    function spend(
        address newImplementation,
        uint256 grace
    ) external {
        MarketLedger.Layout storage $ = MarketLedger.layout();
        (address pending, uint256 eta) = ($.pendingImplementation, $.upgradeEta);
        if (pending == address(0) || newImplementation != pending) revert UpgradeNotScheduled(newImplementation);
        if (block.timestamp < eta) revert UpgradeNotReady(newImplementation, eta);
        if (block.timestamp > eta + grace) revert UpgradeExpired(newImplementation, eta + grace);

        bytes32 scheduled = $.pendingCodehash;
        bytes32 found = newImplementation.codehash;
        if (found != scheduled) revert ImplementationCodeChanged(newImplementation, scheduled, found);

        delete $.pendingImplementation;
        delete $.upgradeEta;
        delete $.pendingCodehash;
    }

    function _firstByte(
        address account
    ) private view returns (bytes1 first) {
        assembly ("memory-safe") {
            mstore(0x00, 0)
            extcodecopy(account, 0x00, 0, 1)
            first := mload(0x00)
        }
    }
}
