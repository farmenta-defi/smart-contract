// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {PermitHash} from "permit2/src/libraries/PermitHash.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {MarketForkTest} from "./MarketForkTest.sol";

/// @title Permit2Signer
/// @notice Signs the Permit2 batch transfers a wallet would ask a borrower for, for every fork
///         suite whose market call pulls tokens through Permit2 (`mintAndDeposit`,
///         `increaseLiquidity`).
abstract contract Permit2Signer is MarketForkTest {
    /// @dev Permit2's free errors, spelled out because `PermitErrors.sol` pins `pragma 0.8.17`
    ///      exactly and cannot be imported into a 0.8.26 build.
    bytes4 internal constant SIGNATURE_EXPIRED = bytes4(keccak256("SignatureExpired(uint256)"));
    bytes4 internal constant INVALID_NONCE = bytes4(keccak256("InvalidNonce()"));

    function _permission(
        address token,
        uint256 amount
    ) internal pure returns (ISignatureTransfer.TokenPermissions memory) {
        return ISignatureTransfer.TokenPermissions({token: token, amount: amount});
    }

    /// @dev The typehashes come from Permit2's own library and the domain is read live, so
    ///      neither can drift from the contract that checks them. The spender is the market:
    ///      Permit2 hashes in `msg.sender`, so a permit is spendable only by the contract named.
    function _sign(
        uint256 privateKey,
        ISignatureTransfer.PermitBatchTransferFrom memory permit
    ) internal view returns (bytes memory) {
        bytes32[] memory permissions = new bytes32[](permit.permitted.length);
        for (uint256 i; i < permissions.length; ++i) {
            permissions[i] = keccak256(abi.encode(PermitHash._TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i]));
        }
        bytes32 structHash = keccak256(
            abi.encode(
                PermitHash._PERMIT_BATCH_TRANSFER_FROM_TYPEHASH,
                keccak256(abi.encodePacked(permissions)),
                address(market),
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", IEIP712(RobinhoodChain.PERMIT2).DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
