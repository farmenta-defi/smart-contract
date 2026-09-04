// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ForkTest} from "./ForkTest.sol";

/// @title PositionMinter
/// @notice Mints Uniswap v4 positions inside the fork, so tests can hold shapes the chain
///         does not happen to contain.
/// @dev Real positions prove valuation matches the messy real world; minted ones cover the
///      edges nobody actually holds — a single-tick range, wei-scale liquidity, a position
///      sitting entirely below the current price. Both were required (no real below-range
///      position survives on this chain: LPs close them rather than sit on a one-sided bag).
///
///      Only ERC-20 pairs are minted here. The native-ETH path needs `msg.value` plumbing
///      that nothing needs yet, and `mintAndDeposit` — the protocol function that will need
///      it — is Phase 2 (§1 #12, §16).
abstract contract PositionMinter is ForkTest, ERC721Holder {
    /// @dev Permit2 sits between the token and PositionManager: the token approves Permit2,
    ///      then Permit2 approves PositionManager. Skipping either half fails inside
    ///      `modifyLiquidities` with an opaque settle error.
    function _fundAndApprove(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1
    ) internal {
        _fundAndApproveOne(Currency.unwrap(key.currency0), amount0);
        _fundAndApproveOne(Currency.unwrap(key.currency1), amount1);
    }

    function _fundAndApproveOne(
        address token,
        uint256 amount
    ) internal {
        deal(token, address(this), amount);
        IERC20(token).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IAllowanceTransfer(RobinhoodChain.PERMIT2)
            .approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    /// @notice Mints a position owned by the test contract.
    /// @dev `nextTokenId()` is read before minting because `modifyLiquidities` returns
    ///      nothing — the same trick `mintAndDeposit` will use (§4.1).
    function _mint(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity
    ) internal returns (uint256 tokenId) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }
}
