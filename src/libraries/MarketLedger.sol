// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ICollateralPolicy} from "../interfaces/ICollateralPolicy.sol";

/// @title MarketLedger
/// @notice `FarmentaMarket`'s storage layout, in the one place both it and its delegatecall
///         libraries can name (ARCHITECTURE §4.1).
/// @dev The layout itself has not changed: the same ERC-7201 namespace and field order keep
///      every deployed proxy slot fixed. A second copy could quietly diverge when one library
///      adds a field, so the shared layout is declared once.
library MarketLedger {
    /// @notice A position held as collateral, and what is owed against it.
    /// @param owner The address that deposited it, and the only one who may take it back.
    /// @param tier The collateral tier it was accepted under, retained for borrowing checks.
    /// @param debtShares Share of `totalBorrows` owed by this collateral position.
    /// @param poolKeyId The pool it sits in, retained for the per-pool debt cap.
    struct Loan {
        address owner;
        ICollateralPolicy.Tier tier;
        uint256 debtShares;
        PoolId poolKeyId;
    }

    /// @custom:storage-location erc7201:farmenta.storage.Market
    /// @param tier Which tier this proxy accepts. It is storage, not immutable, because one
    ///        implementation serves both markets.
    /// @param pendingImplementation The implementation scheduled to replace this one, or zero
    ///        when no upgrade is scheduled (§4.1, FAR-21). Appended after every field a deployed
    ///        proxy already uses, so none of them moves.
    /// @param upgradeEta The earliest `block.timestamp` at which `pendingImplementation` may be
    ///        installed. It shares the slot of `pendingImplementation`.
    /// @param pendingCodehash The hash of the code `pendingImplementation` held when it was
    ///        scheduled, or zero when no upgrade is scheduled. The slot after the queue's first.
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
        address pendingImplementation;
        uint64 upgradeEta;
        bytes32 pendingCodehash;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("farmenta.storage.Market")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;

    function layout() internal pure returns (Layout storage $) {
        assembly {
            $.slot := LOCATION
        }
    }
}
