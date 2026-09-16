// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";

/// @notice A borrower that is a contract, and so runs code when ETH reaches it.
/// @dev Permit2 verifies a contract owner's signature through ERC-1271, and this one accepts any,
///      which is all a test needs to spend a permit as it. What it is for is `receive`: it notes
///      its USDG balance at the moment the ETH lands, so a test can tell which leg arrived first.
contract ContractBorrower is IERC1271 {
    FarmentaMarket internal immutable market;

    /// @notice This contract's USDG balance when the ETH arrived, read before anything else runs.
    uint256 public usdgOnEthArrival;

    constructor(
        FarmentaMarket market_
    ) {
        market = market_;
    }

    function isValidSignature(
        bytes32,
        bytes memory
    ) external pure returns (bytes4) {
        return IERC1271.isValidSignature.selector;
    }

    function approve(
        address token,
        address spender
    ) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function deposit(
        uint256 tokenId
    ) external {
        IERC721(address(market.positionManager())).approve(address(market), tokenId);
        market.depositCollateral(tokenId);
    }

    function increase(
        uint256 tokenId,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit
    ) external payable {
        market.increaseLiquidity{value: msg.value}(tokenId, liquidity, amount0Max, amount1Max, permit, "");
    }

    /// @notice Set by `armReentry`: the position a re-entrant call names when ETH arrives.
    uint256 public reentrantTokenId;
    bool internal reenter;

    /// @notice Arms one re-entrant call into a guarded market function, made from `receive`.
    /// @dev `repay` of zero is the call to make: it is `nonReentrant`, and with the guard gone it
    ///      succeeds instead of reverting, so a test that expects a revert fails on that mutant.
    function armReentry(
        uint256 tokenId
    ) external {
        reentrantTokenId = tokenId;
        reenter = true;
    }

    receive() external payable {
        usdgOnEthArrival = IERC20(market.asset()).balanceOf(address(this));
        if (reenter) {
            reenter = false;
            market.repay(reentrantTokenId, 0);
        }
    }
}
