// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice Settable Pyth response for borrow-gate tests.
contract MockPyth is IPyth {
    mapping(bytes32 id => Price) internal _prices;

    function setPrice(
        bytes32 id,
        int64 price,
        int32 expo,
        uint256 publishTime
    ) external {
        _prices[id] = Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (Price memory price) {
        return _prices[id];
    }
}
