// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAggregatorV3
/// @notice Minimal Chainlink price feed interface — only what Farmenta reads.
/// @dev Declared locally rather than pulled from `@chainlink/contracts` to avoid a
///      dependency whose pragma range does not match this repo's pinned 0.8.26.
interface IAggregatorV3 {
    /// @notice Decimals of `answer`. Chainlink USD feeds use 8, not 18.
    function decimals() external view returns (uint8);

    /// @notice Human-readable pair, e.g. "ETH / USD". Used to assert a feed address
    ///         points at the pair we think it does.
    function description() external view returns (string memory);

    function version() external view returns (uint256);

    /// @dev `updatedAt` drives the staleness check (≤ 25h, heartbeat 86400s — §5.2).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
