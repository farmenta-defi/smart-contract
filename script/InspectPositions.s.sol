// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {RobinhoodChain} from "../src/constants/RobinhoodChain.sol";
import {PositionAmounts} from "../src/libraries/PositionAmounts.sol";

/// @notice Prints everything `PositionValuer` will need, for candidate fixture positions.
/// @dev Reconnaissance, not a test. Run:
///        forge script script/InspectPositions.s.sol --sig "run(uint256[])" "[913889,1621020]"
///      Uncollected fees exist in v4 only as a fee-growth delta (there is no `tokensOwed`),
///      so this is also the first end-to-end exercise of that read path. Amounts here are
///      computed at the pool's **spot** price; the real valuer uses an oracle-derived price
///      instead (§5.1), so treat these numbers as a shape check, not a valuation.
contract InspectPositions is Script {
    using PositionInfoLibrary for PositionInfo;

    uint256 internal constant FORK_BLOCK = 54_200_000;

    IPositionManager internal posm;
    IStateView internal stateView;

    function run(
        uint256[] calldata tokenIds
    ) external {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        posm = IPositionManager(payable(RobinhoodChain.POSITION_MANAGER));
        stateView = IStateView(RobinhoodChain.STATE_VIEW);

        for (uint256 i; i < tokenIds.length; ++i) {
            _inspect(tokenIds[i]);
        }
    }

    function _inspect(
        uint256 tokenId
    ) internal view {
        (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
        console.log("--------------------------------------------------");
        console.log("tokenId", tokenId);

        if (PositionInfo.unwrap(info) == 0) {
            console.log("  EMPTY / burned");
            return;
        }

        int24 tickLower = info.tickLower();
        int24 tickUpper = info.tickUpper();
        PoolId poolId = key.toId();

        console.log("  currency0", Currency.unwrap(key.currency0));
        console.log("  currency1", Currency.unwrap(key.currency1));
        console.log("  fee / tickSpacing", key.fee, vm.toString(key.tickSpacing));
        console.log("  hooks", address(key.hooks));
        console.log("  range", vm.toString(tickLower), vm.toString(tickUpper));

        bytes32 positionKey = Position.calculatePositionKey(address(posm), tickLower, tickUpper, bytes32(tokenId));
        (uint128 liquidity, uint256 fg0Last, uint256 fg1Last) = stateView.getPositionInfo(poolId, positionKey);
        console.log("  liquidity", liquidity);
        if (liquidity == 0) {
            console.log("  NO LIQUIDITY - unusable as a fixture");
            return;
        }

        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(poolId);
        console.log("  pool tick", vm.toString(tick));
        console.log(
            "  status",
            tick < tickLower ? "BELOW range (all token0)" : tick >= tickUpper ? "ABOVE range (all token1)" : "IN range"
        );

        (uint256 amount0, uint256 amount1) = PositionAmounts.forLiquidity(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity
        );
        console.log("  principal at spot: amount0", amount0);
        console.log("                     amount1", amount1);

        (uint256 fgIn0, uint256 fgIn1) = stateView.getFeeGrowthInside(poolId, tickLower, tickUpper);
        // Uniswap's own guide relies on this subtraction wrapping.
        (uint256 fees0, uint256 fees1) = PositionAmounts.feesOwed(fgIn0, fgIn1, fg0Last, fg1Last, liquidity);
        console.log("  uncollected fee0", fees0);
        console.log("  uncollected fee1", fees1);
    }
}
