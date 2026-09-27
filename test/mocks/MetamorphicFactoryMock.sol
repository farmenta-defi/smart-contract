// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";

/// @dev The ERC-1967 implementation slot, which is what a UUPS upgrade asks a candidate for.
bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

/// @notice A candidate implementation that can remove itself, for the FAR-21 tests.
/// @dev No immutables, so its runtime code is the same wherever it is put.
contract RemovableImplementationMock {
    function proxiableUUID() external pure returns (bytes32) {
        return IMPLEMENTATION_SLOT;
    }

    function remove() external {
        selfdestruct(payable(msg.sender));
    }
}

/// @notice A candidate implementation with other code than the one that was scheduled.
contract OtherImplementationMock {
    function proxiableUUID() external pure returns (bytes32) {
        return IMPLEMENTATION_SLOT;
    }

    function other() external pure returns (bool) {
        return true;
    }
}

/// @notice Leaves at its address whatever runtime code its factory holds at that moment.
/// @dev Its creation code never changes, so CREATE2 puts it at one address every time.
contract MetamorphicMock {
    constructor() {
        bytes memory code = MetamorphicFactoryMock(msg.sender).code();
        assembly ("memory-safe") {
            return(add(code, 0x20), mload(code))
        }
    }
}

/// @notice Puts chosen runtime code at one fixed address, as often as that address is empty.
/// @dev What an owner needs to schedule one thing and install another (FAR-21, review of PR #42).
contract MetamorphicFactoryMock {
    bytes public code;

    /// @notice The address every `deploy` lands on.
    function where() external view returns (address) {
        bytes32 digest = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), bytes32(0), keccak256(type(MetamorphicMock).creationCode))
        );
        return address(uint160(uint256(digest)));
    }

    function deploy(
        bytes memory runtime
    ) public returns (address at) {
        code = runtime;
        at = address(new MetamorphicMock{salt: 0}());
    }

    /// @notice One transaction: removable code is put in place, scheduled, and removed again.
    /// @dev EIP-6780 still lets a contract remove itself in the transaction that created it, so
    ///      the scheduled address holds code while `scheduleUpgrade` runs and none afterwards.
    ///      This factory has to own `market`.
    function deployScheduleAndRemove(
        FarmentaMarket market
    ) external returns (address at) {
        at = deploy(type(RemovableImplementationMock).runtimeCode);
        market.scheduleUpgrade(at);
        RemovableImplementationMock(at).remove();
    }
}
