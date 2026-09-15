// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPyth
/// @notice The read-only Pyth surface used for the optional ETH/USD cross-check.
interface IPyth {
    /// @dev Matches Pyth's `PythStructs.Price`. `price` and `expo` describe a decimal
    ///      value as `price * 10**expo`; `publishTime` is the time the publisher signed it.
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (Price memory price);
}
