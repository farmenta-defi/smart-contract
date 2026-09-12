// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Deliberately appends V2 state in its own ERC-7201 namespace for upgrade tests.
contract FarmentaMarketV2Mock is FarmentaMarket {
    /// @custom:storage-location erc7201:farmenta.storage.MarketV2
    struct MarketV2Storage {
        uint256 upgradeMarker;
    }

    bytes32 private constant MARKET_V2_STORAGE_LOCATION =
        0x776aaca31fe0725a5909334e5c6434a243e19878baea06b6161b1a603dc63200;

    constructor(
        IPositionManager positionManager_,
        ICollateralPolicy policy_,
        IPositionValuer valuer_,
        IPriceOracle oracle_,
        IInterestRateModel interestRateModel_
    ) FarmentaMarket(positionManager_, policy_, valuer_, oracle_, interestRateModel_) {}

    function setUpgradeMarker(
        uint256 marker
    ) external onlyOwner {
        _marketV2Storage().upgradeMarker = marker;
    }

    function upgradeMarker() external view returns (uint256) {
        return _marketV2Storage().upgradeMarker;
    }

    function _marketV2Storage() private pure returns (MarketV2Storage storage $) {
        bytes32 slot = MARKET_V2_STORAGE_LOCATION;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }
}
