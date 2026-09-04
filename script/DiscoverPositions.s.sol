// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {RobinhoodChain} from "../src/constants/RobinhoodChain.sol";

/// @notice Reconnaissance: finds real, live positions to use as test fixtures.
/// @dev `PositionManager` has no `ERC721Enumerable` and log queries are impractical on a
///      100ms-block chain, so this walks tokenIds downward from `nextTokenId` inside a
///      pinned fork and reports which pool each position belongs to.
///
///      Run:
///        forge script script/DiscoverPositions.s.sol --sig "run(uint256,uint256)" 400 0
///
///      Output is meant to be read by a human and then hard-coded into the fixtures — this
///      is a one-off discovery tool, not part of the test suite.
contract DiscoverPositions is Script {
    using PositionInfoLibrary for PositionInfo;

    uint256 internal constant FORK_BLOCK = 54_200_000;

    /// @param count How many tokenIds to walk.
    /// @param skip  How many tokenIds below `nextTokenId` to skip before starting, so
    ///              successive runs can sample different slices of the population.
    function run(
        uint256 count,
        uint256 skip
    ) external {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        IPositionManager posm = IPositionManager(payable(RobinhoodChain.POSITION_MANAGER));

        uint256 start = posm.nextTokenId() - 1 - skip;
        console.log("scanning from tokenId", start, "count", count);
        console.log("tokenId | poolId(bytes25) | tickLower | tickUpper | liquidity");

        uint256 live;
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = start - i;
            (, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
            if (PositionInfo.unwrap(info) == 0) continue;

            uint128 liquidity = posm.getPositionLiquidity(tokenId);
            if (liquidity == 0) continue;

            ++live;
            console.log(tokenId);
            console.logBytes25(info.poolId());
            console.log("  ticks", vm.toString(info.tickLower()), vm.toString(info.tickUpper()));
            console.log("  liquidity", liquidity);
        }
        console.log("live positions found:", live, "of", count);
    }

    /// @notice Samples the whole tokenId range and reports positions in the fixture pools.
    /// @dev Recent tokenIds are dominated by launchpad mints, so a contiguous walk from the
    ///      top finds no blue-chip positions. The ETH/USDG pools are old and their positions
    ///      are spread across the range, so sample with a stride instead.
    function sweep(
        uint256 samples,
        uint256 stride
    ) external {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        IPositionManager posm = IPositionManager(payable(RobinhoodChain.POSITION_MANAGER));

        bytes25 ethUsdgDyn = bytes25(bytes32(0x80399a859416860c92785ff7f994e67ecbcda12d3f0adb75e0c2466b9bfacf30));
        bytes25 ethUsdgPlain = bytes25(bytes32(0x54f7883914619af9105355bf83ed678bcf9f63560218ac61c9963b9503d0ba32));
        bytes25 wethUsdgPlain = bytes25(bytes32(0x84bd4e2d8be11aeb0afc1195b38f587b61e90068548f1063fdbe448fb8cad0b6));

        uint256 top = posm.nextTokenId() - 1;
        uint256 hits;
        for (uint256 i; i < samples; ++i) {
            uint256 tokenId = top - i * stride;
            if (tokenId == 0 || tokenId > top) break;

            (, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
            bytes25 pid = info.poolId();
            string memory which;
            if (pid == ethUsdgDyn) which = "ETH/USDG-DYN";
            else if (pid == ethUsdgPlain) which = "ETH/USDG-PLAIN";
            else if (pid == wethUsdgPlain) which = "WETH/USDG-PLAIN";
            else continue;

            uint128 liquidity = posm.getPositionLiquidity(tokenId);
            if (liquidity == 0) continue;

            ++hits;
            console.log("HIT", which, tokenId);
            console.log("  ticks", vm.toString(info.tickLower()), vm.toString(info.tickUpper()));
            console.log("  liquidity", liquidity);
        }
        console.log("hits:", hits, "sampled:", samples);
    }

    /// @notice Same walk, but only reports positions in one pool.
    /// @param poolIdPrefix The pool's id truncated to 25 bytes, as stored in `PositionInfo`.
    function findInPool(
        uint256 count,
        uint256 skip,
        bytes25 poolIdPrefix
    ) external {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        IPositionManager posm = IPositionManager(payable(RobinhoodChain.POSITION_MANAGER));

        uint256 start = posm.nextTokenId() - 1 - skip;
        uint256 hits;
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = start - i;
            (PoolKey memory key, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
            if (info.poolId() != poolIdPrefix) continue;

            uint128 liquidity = posm.getPositionLiquidity(tokenId);
            if (liquidity == 0) continue;

            ++hits;
            console.log("HIT tokenId", tokenId);
            console.log("  ticks", vm.toString(info.tickLower()), vm.toString(info.tickUpper()));
            console.log("  liquidity", liquidity);
            console.log("  fee/tickSpacing", key.fee, vm.toString(key.tickSpacing));
        }
        console.log("hits:", hits, "scanned:", count);
    }
}
