// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Settable Chainlink feed for oracle unit tests.
contract MockAggregatorV3 is IAggregatorV3 {
    uint8 internal immutable _decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(
        uint8 decimals_
    ) {
        _decimals = decimals_;
    }

    function setAnswer(
        int256 answer_,
        uint256 updatedAt_
    ) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock / USD";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    function getRoundData(
        uint80 requestedRoundId
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (requestedRoundId != 1) revert();
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
