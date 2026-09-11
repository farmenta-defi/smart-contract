// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IEIP712} from "permit2/src/interfaces/IEIP712.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {PermitHash} from "permit2/src/libraries/PermitHash.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

/// @notice Mints positions straight into the market, through the deployed PositionManager
///         and Permit2.
/// @dev What this path gets wrong, it gets wrong quietly: a tokenId read one call too late,
///      an approval layer left out, change stranded in the market. None of that shows against
///      a mock, so every test here runs through the real contracts at the pinned block.
contract MarketMintAndDepositForkTest is MarketForkTest {
    uint256 internal constant BORROWER_PK = 0xB0B5EED;

    /// @dev What the borrower brings, and what each leg's maximum is set to by default.
    uint256 internal constant WETH_BUDGET = 10 ether;
    uint256 internal constant USDG_BUDGET = 100_000e6;

    /// @dev Lenders' USDG already in the market, so a mint that dipped into it would show.
    uint256 internal constant LENDER_DEPOSIT = 50_000e6;

    /// @dev Comfortably above the $50 floor over a range ten spacings either side of the price.
    uint256 internal constant LIQUIDITY = 1e15;

    address internal borrower;
    PoolKey internal wethKey;

    /// @dev Everything a mint may move, read in one place.
    struct Balances {
        uint256 borrowerWeth;
        uint256 borrowerUsdg;
        uint256 marketWeth;
        uint256 marketUsdg;
        uint256 poolManagerWeth;
        uint256 poolManagerUsdg;
    }

    function setUp() public override {
        super.setUp();

        borrower = vm.addr(BORROWER_PK);
        vm.label(borrower, "borrower");

        // Borrow the WETH/USDG pool's key from a real position rather than building it: a
        // hand-made key that differs in any field addresses a different pool.
        wethKey = _keyOf(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);

        // The borrower's one-time Permit2 setup, which a wallet does once per token.
        deal(RobinhoodChain.WETH, borrower, WETH_BUDGET);
        deal(RobinhoodChain.USDG, borrower, USDG_BUDGET);
        vm.startPrank(borrower);
        IERC20(RobinhoodChain.WETH).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IERC20(RobinhoodChain.USDG).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        vm.stopPrank();

        address lender = address(0x1E4DE2);
        deal(RobinhoodChain.USDG, lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        IERC20(RobinhoodChain.USDG).approve(address(market), LENDER_DEPOSIT);
        market.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();
    }

    /* --------------------------------- happy path ----------------------------- */

    /// @notice One transaction: tokens in, position minted, custody taken, loan recorded.
    function test_mintsIntoCustodyAndRecordsTheCaller() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);

        // Signed first: reading Permit2's domain is a call, and would otherwise be the one the
        // expectation below is checked against.
        uint256 expectedId = positionManager.nextTokenId();
        vm.expectEmit(true, true, false, false, address(market));
        emit FarmentaMarket.CollateralDeposited(expectedId, borrower);
        vm.prank(borrower);
        uint256 tokenId = market.mintAndDeposit(p, permit, signature);

        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        FarmentaMarket.Loan memory loan = market.loanOf(tokenId);
        assertEq(loan.owner, borrower, "caller not recorded");
        assertEq(loan.debtShares, 0, "a fresh deposit owes nothing");
    }

    /// @notice The id recorded is the id minted.
    /// @dev The regression the spec warns about. `modifyLiquidities` returns nothing, so the
    ///      market reads `nextTokenId()` before minting. Read afterwards it would be one past
    ///      the real position — a token that does not exist yet, recorded as collateral, and
    ///      minted to whoever comes next. Each assertion below fails on that off-by-one.
    function test_recordsTheTokenIdActuallyMinted() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        uint256 before = positionManager.nextTokenId();

        uint256 tokenId = _mintAndDeposit(p, 0);

        assertEq(tokenId, before, "returned id is not the one PositionManager assigned");
        assertEq(positionManager.nextTokenId(), before + 1, "exactly one position should have been minted");
        assertEq(market.loanOf(tokenId).owner, borrower, "the minted id is not the one recorded");
        assertEq(nft.ownerOf(tokenId), address(market), "the recorded id is not held by the market");
        assertEq(positionManager.getPositionLiquidity(tokenId), LIQUIDITY, "the recorded id holds other liquidity");

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(wethKey.toId()), "the recorded id is in another pool");
        assertEq(info.tickLower(), p.tickLower, "the recorded id has another lower tick");
        assertEq(info.tickUpper(), p.tickUpper, "the recorded id has another upper tick");

        // The id a late read would have produced is nobody's collateral.
        assertEq(market.loanOf(tokenId + 1).owner, address(0), "a loan was recorded against an unminted token");
    }

    /// @notice The borrower pays exactly what the pool took, and the market ends where it began.
    /// @dev Each leg is pulled at its maximum and the change comes back. PoolManager's balance
    ///      is the independent witness: what it gained is the true cost, so the borrower must be
    ///      down by exactly that. The market's USDG is lenders' money and must not move at all —
    ///      a mint that settled out of it, or paid change out of it, shows up here.
    function test_returnsWhatTheMintDidNotSpend() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);

        Balances memory before = _balances();
        _mintAndDeposit(p, 0);
        Balances memory afterMint = _balances();

        uint256 wethSpent = afterMint.poolManagerWeth - before.poolManagerWeth;
        uint256 usdgSpent = afterMint.poolManagerUsdg - before.poolManagerUsdg;
        assertGt(wethSpent, 0, "an in-range mint costs WETH");
        assertGt(usdgSpent, 0, "an in-range mint costs USDG");
        assertLt(wethSpent, WETH_BUDGET, "the WETH maximum should leave change");
        assertLt(usdgSpent, USDG_BUDGET, "the USDG maximum should leave change");

        assertEq(before.borrowerWeth - afterMint.borrowerWeth, wethSpent, "borrower paid other than the WETH cost");
        assertEq(before.borrowerUsdg - afterMint.borrowerUsdg, usdgSpent, "borrower paid other than the USDG cost");
        assertEq(afterMint.marketWeth, before.marketWeth, "WETH was left in the market");
        assertEq(afterMint.marketUsdg, before.marketUsdg, "lenders' USDG moved");
    }

    /// @notice What remains of the market's settle allowance is exactly the change, and it
    ///         dies with the block.
    /// @dev The allowance PositionManager holds over the market is sized to one mint's
    ///      maximum, so it can never reach lenders' USDG. Its remainder is what the market read
    ///      the refund from; if the two disagreed, the change paid out would be wrong.
    function test_theSettleAllowanceIsSpentOrExpired() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);

        Balances memory before = _balances();
        _mintAndDeposit(p, 0);
        Balances memory afterMint = _balances();

        (uint160 left, uint48 expiration,) = IAllowanceTransfer(RobinhoodChain.PERMIT2)
            .allowance(address(market), RobinhoodChain.USDG, RobinhoodChain.POSITION_MANAGER);
        uint256 usdgSpent = afterMint.poolManagerUsdg - before.poolManagerUsdg;
        assertEq(left, USDG_BUDGET - usdgSpent, "the leftover allowance is not the change");
        assertEq(expiration, block.timestamp, "the allowance outlives the block");
    }

    /// @notice Minting in ends in the same state as depositing an equivalent position.
    /// @dev The same position is built both ways — through `mintAndDeposit`, and minted
    ///      outside then handed over with `depositCollateral` — and the results compared. Both
    ///      then come back out through `withdrawCollateral`, the half of "identical" that
    ///      matters most to the borrower.
    function test_endsInTheSameStateAsDepositCollateral() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);

        uint256 minted = _mintAndDeposit(p, 0);

        _fundAndApprove(wethKey, WETH_BUDGET, USDG_BUDGET);
        uint256 deposited = _mint(wethKey, p.tickLower, p.tickUpper, LIQUIDITY);
        nft.transferFrom(address(this), borrower, deposited);

        vm.startPrank(borrower);
        nft.approve(address(market), deposited);
        market.depositCollateral(deposited);
        vm.stopPrank();

        assertEq(
            valuer.value(minted).principalUsd,
            valuer.value(deposited).principalUsd,
            "the two positions should be equivalent"
        );
        assertEq(nft.ownerOf(minted), nft.ownerOf(deposited), "custody differs");
        assertEq(market.loanOf(minted).owner, market.loanOf(deposited).owner, "recorded owner differs");
        assertEq(market.loanOf(minted).debtShares, market.loanOf(deposited).debtShares, "recorded debt differs");

        vm.startPrank(borrower);
        market.withdrawCollateral(minted, borrower);
        market.withdrawCollateral(deposited, borrower);
        vm.stopPrank();

        assertEq(nft.ownerOf(minted), borrower, "a minted position did not come back");
        assertEq(nft.ownerOf(deposited), borrower, "a deposited position did not come back");
        assertEq(market.loanOf(minted).owner, address(0), "the minted record was not cleared");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev A range ten spacings either side of the oracle price, with the given maxima.
    function _inRange(
        PoolKey memory key,
        uint256 liquidity,
        uint256 max0,
        uint256 max1
    ) internal pure returns (FarmentaMarket.MintParams memory) {
        int24 spacing = key.tickSpacing;
        int24 mid = _alignedOracleTick(spacing);
        return FarmentaMarket.MintParams({
            poolKey: key,
            tickLower: mid - 10 * spacing,
            tickUpper: mid + 10 * spacing,
            liquidity: liquidity,
            amount0Max: uint128(max0),
            amount1Max: uint128(max1),
            hookData: ""
        });
    }

    /// @dev Signs, then submits as the borrower, sending the ETH maximum for a native pool.
    function _mintAndDeposit(
        FarmentaMarket.MintParams memory p,
        uint256 nonce
    ) internal returns (uint256 tokenId) {
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, nonce);
        uint256 value = p.poolKey.currency0.isAddressZero() ? p.amount0Max : 0;

        vm.prank(borrower);
        tokenId = market.mintAndDeposit{value: value}(p, permit, signature);
    }

    /// @dev The permit a wallet would ask the borrower to sign: each ERC-20 leg at its maximum,
    ///      valid for an hour.
    function _signedPermit(
        FarmentaMarket.MintParams memory p,
        uint256 nonce
    ) internal view returns (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) {
        permit = _permitFor(p, nonce, block.timestamp + 1 hours);
        signature = _sign(BORROWER_PK, permit);
    }

    function _permitFor(
        FarmentaMarket.MintParams memory p,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (ISignatureTransfer.PermitBatchTransferFrom memory permit) {
        address token0 = Currency.unwrap(p.poolKey.currency0);
        address token1 = Currency.unwrap(p.poolKey.currency1);
        if (token0 == RobinhoodChain.NATIVE) {
            permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
            permit.permitted[0] = _permission(token1, p.amount1Max);
        } else {
            permit.permitted = new ISignatureTransfer.TokenPermissions[](2);
            permit.permitted[0] = _permission(token0, p.amount0Max);
            permit.permitted[1] = _permission(token1, p.amount1Max);
        }
        permit.nonce = nonce;
        permit.deadline = deadline;
    }

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

    function _balances() internal view returns (Balances memory b) {
        IERC20 weth = IERC20(RobinhoodChain.WETH);
        IERC20 usdg = IERC20(RobinhoodChain.USDG);
        b.borrowerWeth = weth.balanceOf(borrower);
        b.borrowerUsdg = usdg.balanceOf(borrower);
        b.marketWeth = weth.balanceOf(address(market));
        b.marketUsdg = usdg.balanceOf(address(market));
        b.poolManagerWeth = weth.balanceOf(RobinhoodChain.POOL_MANAGER);
        b.poolManagerUsdg = usdg.balanceOf(RobinhoodChain.POOL_MANAGER);
    }
}
