// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";

/// @title MarketLedger
/// @notice `FarmentaMarket`'s ERC-7201 storage layout for the market and linked libraries.
/// @dev The field order and namespace are frozen: every proxy already uses these slots.
library MarketLedger {
    struct Loan {
        address owner;
        ICollateralPolicy.Tier tier;
        uint256 debtShares;
        PoolId poolKeyId;
    }

    /// @custom:storage-location erc7201:farmenta.storage.Market
    struct Layout {
        ICollateralPolicy.Tier tier;
        mapping(uint256 tokenId => Loan) loans;
        mapping(PoolId poolId => uint256) poolDebtShares;
        uint256 totalBorrowShares;
        uint256 totalBorrows;
        uint256 borrowIndex;
        uint256 lastAccrual;
        uint256 reserves;
        uint16 reserveFactorBps;
        uint16 reserveFloorBps;
        uint256 totalReservesWithdrawn;
    }

    bytes32 internal constant LOCATION = 0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;

    function layout() internal pure returns (Layout storage $) {
        assembly {
            $.slot := LOCATION
        }
    }
}
