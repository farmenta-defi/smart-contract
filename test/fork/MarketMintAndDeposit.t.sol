// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";
import {SignatureVerification} from "permit2/src/libraries/SignatureVerification.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {MarketLedger} from "../../src/libraries/MarketLedger.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {Permit2Signer} from "../base/Permit2Signer.sol";
import {VaultRedeemingHook} from "../mocks/VaultRedeemingHook.sol";

/// @notice Mints positions straight into the market, through the deployed PositionManager
///         and Permit2.
/// @dev What this path gets wrong, it gets wrong quietly: a tokenId read one call too late,
///      an approval layer left out, change stranded in the market. None of that shows against
///      a mock, so every test here runs through the real contracts at the pinned block.
contract MarketMintAndDepositForkTest is Permit2Signer {
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
        MarketLedger.Loan memory loan = market.loanOf(tokenId);
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

    /// @notice The market grants no allowance to anyone, on either layer.
    /// @dev Replaces the test that pinned both approval layers (FAR-45). Mint used to settle from
    ///      the market, which needed token → Permit2 → PositionManager at the maximum; it now
    ///      pays PositionManager directly, as `increaseLiquidity` does. An allowance appearing
    ///      here would mean the market became a payer again, the design that let a hook redeem
    ///      at a price the borrower's tokens had inflated.
    function test_grantsNoAllowance() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);

        vm.expectCall(RobinhoodChain.PERMIT2, abi.encodeWithSelector(IAllowanceTransfer.approve.selector), 0);
        vm.expectCall(RobinhoodChain.WETH, abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.expectCall(RobinhoodChain.USDG, abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.prank(borrower);
        market.mintAndDeposit(p, permit, signature);

        for (uint256 i; i < 2; ++i) {
            address token = i == 0 ? RobinhoodChain.WETH : RobinhoodChain.USDG;
            assertEq(IERC20(token).allowance(address(market), RobinhoodChain.PERMIT2), 0, "token -> Permit2 allowance");
            (uint160 allowed,,) = IAllowanceTransfer(RobinhoodChain.PERMIT2)
                .allowance(address(market), token, RobinhoodChain.POSITION_MANAGER);
            assertEq(allowed, 0, "Permit2 -> PositionManager allowance");
        }
    }

    /// @notice Even with both approval layers standing, the market never pays for a mint.
    /// @dev A proxy upgraded from the implementation before FAR-45 keeps the allowances its old
    ///      mints granted: `token → Permit2 → PositionManager` at the maximum. `SETTLE` with
    ///      `payerIsUser = true` would then draw a leg from lenders' cash through Permit2.
    ///      Nothing here is a payer, so the market's balances do not move.
    function test_aStandingAllowanceStillDoesNotLetTheMarketPay() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        vm.startPrank(address(market));
        IERC20(RobinhoodChain.WETH).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IERC20(RobinhoodChain.USDG).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IAllowanceTransfer(RobinhoodChain.PERMIT2)
            .approve(RobinhoodChain.WETH, RobinhoodChain.POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(RobinhoodChain.PERMIT2)
            .approve(RobinhoodChain.USDG, RobinhoodChain.POSITION_MANAGER, type(uint160).max, type(uint48).max);
        vm.stopPrank();

        Balances memory before = _balances();
        _mintAndDeposit(_inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET), 0);
        Balances memory afterMint = _balances();

        assertEq(afterMint.marketUsdg, before.marketUsdg, "lenders' USDG paid for the mint");
        assertEq(afterMint.marketWeth, before.marketWeth, "the market's WETH paid for the mint");
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

    /* --------------------------------- native ETH ----------------------------- */

    /// @notice A native-ETH pool spends from `msg.value` and sends the rest back.
    /// @dev ETH is currency0 and never touches Permit2. The market forwards `msg.value` to
    ///      PositionManager, `SETTLE_PAIR` pays the pool out of it, and `SWEEP` returns what is
    ///      left straight to the borrower. PoolManager's balance is again the witness. The
    ///      market must hold no more ETH afterwards than before, because ETH left there has no
    ///      way out (§15 no. 12).
    ///
    ///      `SWEEP` hands over PositionManager's whole ETH balance, so any stray ETH already
    ///      sitting there reaches the borrower too; the borrower's side is measured net of it.
    ///      The pool has tick spacing 1, so ten spacings are a tenth as wide as in the WETH
    ///      pool, and the liquidity is raised to keep the position above the floor.
    function test_nativePoolSpendsEthAndReturnsTheRest() public {
        PoolKey memory ethKey = _keyOf(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        _listPool(ethKey, TierPresets.blueChip().minPositionUsd, 0);
        uint256 ethBudget = 10 ether;
        vm.deal(borrower, ethBudget);
        FarmentaMarket.MintParams memory p = _inRange(ethKey, 10 * LIQUIDITY, ethBudget, USDG_BUDGET);

        uint256 borrowerEth = borrower.balance;
        uint256 marketEth = address(market).balance;
        uint256 strayEth = RobinhoodChain.POSITION_MANAGER.balance;
        uint256 poolManagerEth = RobinhoodChain.POOL_MANAGER.balance;
        Balances memory before = _balances();

        uint256 tokenId = _mintAndDeposit(p, 0);

        uint256 ethSpent = RobinhoodChain.POOL_MANAGER.balance - poolManagerEth;
        assertGt(ethSpent, 0, "an in-range mint costs ETH");
        assertLt(ethSpent, ethBudget, "the ETH maximum should leave change");
        assertEq(borrower.balance, borrowerEth - ethSpent + strayEth, "borrower paid other than the ETH cost");
        assertEq(RobinhoodChain.POSITION_MANAGER.balance, 0, "ETH was left in PositionManager");
        assertEq(address(market).balance, marketEth, "ETH was left in the market");

        Balances memory afterMint = _balances();
        uint256 usdgSpent = afterMint.poolManagerUsdg - before.poolManagerUsdg;
        assertGt(usdgSpent, 0, "an in-range mint costs USDG");
        assertEq(before.borrowerUsdg - afterMint.borrowerUsdg, usdgSpent, "borrower paid other than the USDG cost");
        assertEq(afterMint.marketUsdg, before.marketUsdg, "lenders' USDG moved");

        assertEq(nft.ownerOf(tokenId), address(market), "market does not own the position");
        assertEq(market.loanOf(tokenId).owner, borrower, "caller not recorded");
    }

    /// @notice An ETH leg that would cost more than `amount0Max` reverts, and the ETH comes back.
    /// @dev ETH settles along a different path from an ERC-20 leg — out of the value sent, not
    ///      through Permit2 — so its maximum is checked on its own.
    function test_nativeCostAboveTheEthMaximumReverts() public {
        PoolKey memory ethKey = _keyOf(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        _listPool(ethKey, TierPresets.blueChip().minPositionUsd, 0);
        vm.deal(borrower, 1);
        FarmentaMarket.MintParams memory p = _inRange(ethKey, 10 * LIQUIDITY, 1, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);

        vm.prank(borrower);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        market.mintAndDeposit{value: 1}(p, permit, signature);

        assertEq(borrower.balance, 1, "a refused mint kept the borrower's ETH");
    }

    /* ---------------------------------- refusals ------------------------------ */

    /// @notice A pool nobody listed is refused, and the whole mint unwinds.
    /// @dev Admission runs once the position exists, so a refusal has to revert everything.
    ///      A position left behind would sit in the market belonging to nobody it can name,
    ///      and the borrower's tokens would be locked inside it.
    function test_unlistedPoolRevertsAndLeavesNothingBehind() public {
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);
        Balances memory before = _balances();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolNotListed.selector, wethKey.toId()));
        market.mintAndDeposit(p, permit, signature);

        _assertNothingMoved(before, nextId);
    }

    /// @notice A frozen pool takes no new positions by minting either.
    /// @dev §6.5 names `mintAndDeposit` among what delisting stops, next to `depositCollateral`.
    ///      Freezing is how a pool is wound down, so a mint that slipped past it would be adding
    ///      exposure to the very pool the owner is emptying.
    function test_frozenPoolRevertsAndLeavesNothingBehind() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        vm.prank(owner);
        policy.setFrozen(wethKey.toId(), true);

        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);
        Balances memory before = _balances();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.PoolFrozenForNewPositions.selector, wethKey.toId()));
        market.mintAndDeposit(p, permit, signature);

        _assertNothingMoved(before, nextId);
    }

    /// @notice A listed pool whose hook no longer passes is refused at mint time.
    /// @dev §6.1 is checked again at intake, not only at listing: an allowlisting can be
    ///      revoked, and a mint must not be the way around that. No pool on the chain pairs
    ///      USDG with a hook that touches remove-liquidity, so one is created here. Its hook
    ///      address carries only the `afterRemoveLiquidity` bit and has no code — adding
    ///      liquidity never calls it, and that one bit is all the policy reads.
    function test_hookThatFailsTheBitCheckRevertsAndLeavesNothingBehind() public {
        address hook = address((uint160(0xF00D) << 144) | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        PoolKey memory key = _initPool(hook);

        vm.prank(owner);
        policy.setHookAllowlist(hook, true);
        _listPool(key, TierPresets.blueChip().minPositionUsd, 0);
        vm.prank(owner);
        policy.setHookAllowlist(hook, false);

        FarmentaMarket.MintParams memory p = _inRange(key, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);
        Balances memory before = _balances();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(CollateralPolicy.HookNotPermitted.selector, hook));
        market.mintAndDeposit(p, permit, signature);

        _assertNothingMoved(before, nextId);
    }

    /// @notice A vault deposit made from inside the mint is refused, so it cannot be paid out as
    ///         change.
    /// @dev ERC-20 change is whatever the market holds above its balance from before the caller
    ///      paid in, so anything else landing mid-mint would be counted with it. A vault deposit
    ///      is the one inflow that hands its sender something back: a pool hook that deposits
    ///      while liquidity is added would end up holding shares, and the minter holding the
    ///      deposit. The hook passes the §6.1 bit check — that check is about removing liquidity,
    ///      not adding it — so listing alone would not stop it. `_deposit` refuses re-entry, the
    ///      hook's call fails, and the whole mint unwinds.
    function test_aVaultDepositFromInsideTheMintIsRefused() public {
        address hook = address((uint160(0xDEF0) << 144) | Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        deployCodeTo("MarketMintAndDeposit.t.sol:VaultDepositingHook", abi.encode(market), hook);
        deal(RobinhoodChain.USDG, hook, 10_000e6);

        PoolKey memory key = _initPool(hook);
        _listPool(key, TierPresets.blueChip().minPositionUsd, 0);

        FarmentaMarket.MintParams memory p = _inRange(key, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);
        Balances memory before = _balances();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hook,
                IHooks.afterAddLiquidity.selector,
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        market.mintAndDeposit(p, permit, signature);

        _assertNothingMoved(before, nextId);
    }

    /// @notice A hook that redeems its vault shares from inside the mint gets exactly what they
    ///         were worth, and the borrower pays nothing for it.
    /// @dev §4.1 v0.26: every market function that calls out must survive a vault exit from
    ///      inside the call. The hook passes the §6.1 bit check, which is about removing
    ///      liquidity, not adding it. When the borrower's tokens were pulled into the market
    ///      they counted toward `totalAssets` while the hook ran: shares worth 20,000 USDG
    ///      redeemed for 48,571, and the borrower's change paid the difference (FAR-45). The
    ///      tokens now go straight to PositionManager, so the share price the hook sees is the
    ///      one everyone else sees.
    ///
    ///      The pool is listed with the hook allowlisted, then the hook deposits: a hook with no
    ///      shares does nothing, so the order only decides when the redeem arms.
    function test_aRedeemFromInsideTheHookGainsNothing() public {
        address hook = address((uint160(0xDEF1) << 144) | Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        deployCodeTo("VaultRedeemingHook.sol:VaultRedeemingHook", abi.encode(market), hook);
        PoolKey memory key = _initPool(hook);
        _listPool(key, TierPresets.blueChip().minPositionUsd, 0);

        deal(RobinhoodChain.USDG, hook, 20_000e6);
        VaultRedeemingHook(hook).deposit(20_000e6);
        uint256 fair = market.previewRedeem(market.balanceOf(hook));

        FarmentaMarket.MintParams memory p = _inRange(key, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        uint256 strayUsdg = IERC20(RobinhoodChain.USDG).balanceOf(RobinhoodChain.POSITION_MANAGER);
        Balances memory before = _balances();
        _mintAndDeposit(p, 0);
        Balances memory afterMint = _balances();

        uint256 redeemed = VaultRedeemingHook(hook).redeemed();
        assertGt(redeemed, 0, "the redeem must actually run inside the mint");
        assertLe(redeemed, fair, "a share redeemed mid-mint is worth more than before it");

        uint256 usdgSpent = afterMint.poolManagerUsdg - before.poolManagerUsdg;
        assertEq(
            before.borrowerUsdg - afterMint.borrowerUsdg, usdgSpent - strayUsdg, "the borrower paid for the redemption"
        );
        assertEq(afterMint.marketUsdg, before.marketUsdg - redeemed, "the market paid out more than the redeem");
    }

    /// @notice A position worth less than the floor is refused, however it was made.
    /// @dev Minting through the market earns no exemption from §6.2's minimum, which exists
    ///      because dust cannot be valued precisely (§5.1).
    function test_positionBelowTheMinimumReverts() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, 1e9, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);
        Balances memory before = _balances();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.PositionBelowMinimum.selector);
        market.mintAndDeposit(p, permit, signature);

        _assertNothingMoved(before, nextId);
    }

    /// @notice A mint that would cost more than either maximum reverts.
    /// @dev The maxima are also what the permit pulls, so this is what keeps a mint from
    ///      needing more than the caller sent in.
    function test_costAboveEitherMaximumReverts() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);

        FarmentaMarket.MintParams memory tightWeth = _inRange(wethKey, LIQUIDITY, 1, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(tightWeth, 0);
        vm.prank(borrower);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        market.mintAndDeposit(tightWeth, permit, signature);

        FarmentaMarket.MintParams memory tightUsdg = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, 1);
        (permit, signature) = _signedPermit(tightUsdg, 0);
        vm.prank(borrower);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        market.mintAndDeposit(tightUsdg, permit, signature);
    }

    /// @notice The permit must carry one entry per ERC-20 leg, two for this pair.
    /// @dev The count check lives in the helper `increaseLiquidity` (FAR-9) shares, so both callers
    ///      test it. A short permit must be refused by name, not by an arithmetic panic further in.
    function test_permitMustCarryOneEntryPerErc20Leg() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permitFor(p, 0, block.timestamp + 1 hours);
        ISignatureTransfer.TokenPermissions[] memory one = new ISignatureTransfer.TokenPermissions[](1);
        one[0] = permit.permitted[0];
        permit.permitted = one;
        bytes memory signature = _sign(BORROWER_PK, permit);

        vm.prank(borrower);
        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.mintAndDeposit(p, permit, signature);
    }

    function test_expiredPermitReverts() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);

        uint256 deadline = block.timestamp - 1;
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permitFor(p, 0, deadline);
        bytes memory signature = _sign(BORROWER_PK, permit);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(SIGNATURE_EXPIRED, deadline));
        market.mintAndDeposit(p, permit, signature);
    }

    /// @notice A permit mints once. Replaying it reverts, even with the tokens to pay again.
    function test_replayedPermitReverts() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);

        vm.prank(borrower);
        market.mintAndDeposit(p, permit, signature);

        // Topped back up, so the only thing wrong with the second attempt is the nonce.
        deal(RobinhoodChain.WETH, borrower, WETH_BUDGET);
        deal(RobinhoodChain.USDG, borrower, USDG_BUDGET);

        vm.prank(borrower);
        vm.expectRevert(INVALID_NONCE);
        market.mintAndDeposit(p, permit, signature);
    }

    /// @notice A permit can only be spent by the borrower who signed it.
    /// @dev The market spends a permit as `msg.sender`'s, because that is who the position is
    ///      recorded to. A borrower's broadcast permit submitted by anyone else fails the
    ///      signature check instead of buying the submitter a position with the borrower's
    ///      tokens.
    function test_someoneElsesPermitCannotBeSpent() public {
        _listPool(wethKey, TierPresets.blueChip().minPositionUsd, 0);
        FarmentaMarket.MintParams memory p = _inRange(wethKey, LIQUIDITY, WETH_BUDGET, USDG_BUDGET);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) = _signedPermit(p, 0);
        Balances memory before = _balances();
        uint256 nextId = positionManager.nextTokenId();

        vm.prank(address(0xBAD));
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        market.mintAndDeposit(p, permit, signature);

        _assertNothingMoved(before, nextId);
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev A refused mint leaves no position and moves no token, the borrower's or the market's.
    function _assertNothingMoved(
        Balances memory before,
        uint256 nextId
    ) internal view {
        Balances memory now_ = _balances();
        assertEq(positionManager.nextTokenId(), nextId, "a position was left behind");
        assertEq(now_.borrowerWeth, before.borrowerWeth, "the borrower's WETH moved");
        assertEq(now_.borrowerUsdg, before.borrowerUsdg, "the borrower's USDG moved");
        assertEq(now_.marketWeth, before.marketWeth, "the market's WETH moved");
        assertEq(now_.marketUsdg, before.marketUsdg, "the market's USDG moved");
        assertEq(now_.poolManagerWeth, before.poolManagerWeth, "WETH reached the pool");
        assertEq(now_.poolManagerUsdg, before.poolManagerUsdg, "USDG reached the pool");
    }

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
            // Safe: every maximum a test passes is a budget of at most 100,000 tokens, far below
            // 2^128 in either token's base units.
            // forge-lint: disable-next-line(unsafe-typecast)
            amount0Max: uint128(max0),
            // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @dev A fresh WETH/USDG pool behind `hook`, opened at the fixture pool's price. Nothing on
    ///      the chain pairs USDG with the hook shapes these tests need, so they make their own.
    function _initPool(
        address hook
    ) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: wethKey.currency0, currency1: wethKey.currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)
        });
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(wethKey.toId());
        poolManager.initialize(key, sqrtPriceX96);
    }
}

/// @notice A hook that deposits into the market while liquidity is being added to its pool.
/// @dev The re-entry `FarmentaMarket._deposit` refuses. Were it allowed, the hook would keep the
///      shares while the deposited USDG sat above the market's pre-mint balance and was paid
///      out as the minter's change.
contract VaultDepositingHook {
    FarmentaMarket internal immutable market;

    constructor(
        FarmentaMarket market_
    ) {
        market = market_;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        IERC20 usdg = IERC20(market.asset());
        uint256 amount = usdg.balanceOf(address(this));
        usdg.approve(address(market), amount);
        market.deposit(amount, address(this));
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
