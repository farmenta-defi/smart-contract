// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {ForkTest} from "../base/ForkTest.sol";

/// @notice Proves the fork harness itself works before anything is built on top of it.
/// @dev If these fail, the RPC endpoint or the pinned block is wrong — not the protocol.
contract HarnessForkTest is ForkTest {
    function test_forkIsRobinhoodChainAtPinnedBlock() public view {
        assertEq(block.chainid, RobinhoodChain.CHAIN_ID, "wrong chain");
        // State, not block.number: on this Arbitrum Orbit chain block.number reports the L1
        // block, and Foundry versions disagree about it. See ForkTest.FORK_NEXT_TOKEN_ID.
        assertEq(positionManager.nextTokenId(), FORK_NEXT_TOKEN_ID, "fork is not at the pinned block");
    }

    function test_positionManagerIsTheUniswapNft() public view {
        assertEq(
            IERC721Metadata(RobinhoodChain.POSITION_MANAGER).name(),
            "Uniswap v4 Positions NFT",
            "not the Uniswap position NFT"
        );
    }

    /// @dev USDG has 6 decimals while ETH/WETH have 18. Every valuation path has to carry
    ///      that asymmetry, so it is asserted rather than assumed.
    function test_tokenDecimals() public view {
        assertEq(IERC20Metadata(RobinhoodChain.USDG).decimals(), RobinhoodChain.USDG_DECIMALS, "USDG decimals moved");
        assertEq(IERC20Metadata(RobinhoodChain.WETH).decimals(), RobinhoodChain.WETH_DECIMALS, "WETH decimals moved");
    }

    function test_fixturePoolsAreInitializedAndLiquid() public view {
        _assertPoolLive(Fixtures.POOL_ETH_USDG_DYN, "ETH/USDG dyn-fee");
        _assertPoolLive(Fixtures.POOL_ETH_USDG_PLAIN, "ETH/USDG plain");
        _assertPoolLive(Fixtures.POOL_WETH_USDG_PLAIN, "WETH/USDG plain");
    }

    /// @dev Uncollected fees exist in v4 only as a fee-growth delta — there is no
    ///      `tokensOwed`. Reading growth is therefore load-bearing for `PositionValuer`.
    function test_feeGrowthIsReadable() public view {
        (uint256 growth0, uint256 growth1) =
            stateView.getFeeGrowthInside(Fixtures.POOL_ETH_USDG_DYN, -200_000, -190_000);
        // A live pool has traded, so at least one side must have accumulated growth.
        assertTrue(growth0 != 0 || growth1 != 0, "no fee growth inside a traded range");
    }

    function _assertPoolLive(
        PoolId poolId,
        string memory label
    ) internal view {
        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, string.concat(label, ": not initialized"));
        assertTrue(tick != 0, string.concat(label, ": suspicious zero tick"));
        assertGt(stateView.getLiquidity(poolId), 0, string.concat(label, ": no active liquidity"));
    }
}
