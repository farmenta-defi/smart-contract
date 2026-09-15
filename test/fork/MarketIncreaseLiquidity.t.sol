// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {Permit2Signer} from "../base/Permit2Signer.sol";
import {ContractBorrower} from "../mocks/ContractBorrower.sol";
import {VaultRedeemingHook} from "../mocks/VaultRedeemingHook.sol";

/// @notice Adds liquidity to positions already held as collateral, through the deployed
///         PositionManager and Permit2.
/// @dev The borrower's tokens go from Permit2 straight to PositionManager, which settles out of
///      its own balance and sweeps the rest back. PoolManager's balance is the independent
///      witness of what an addition cost, and every test that moves tokens checks the borrower
///      paid exactly that while the market's own balances did not move.
contract MarketIncreaseLiquidityForkTest is Permit2Signer {
    uint256 internal constant BORROWER_PK = 0xB0B5EED;

    /// @dev What the borrower brings, and what each leg's maximum is set to by default.
    uint256 internal constant WETH_BUDGET = 10 ether;
    uint256 internal constant USDG_BUDGET = 100_000e6;

    /// @dev Lenders' USDG already in the market, so an addition that dipped into it would show.
    uint256 internal constant LENDER_DEPOSIT = 50_000e6;

    /// @dev Comfortably above the $50 floor over a range ten spacings either side of the price.
    uint128 internal constant LIQUIDITY = 1e15;

    /// @dev `ISignatureTransfer.permitTransferFrom` is overloaded, so its batch selector is
    ///      spelled out.
    bytes4 internal constant PERMIT_BATCH_TRANSFER_FROM = bytes4(
        keccak256("permitTransferFrom(((address,uint256)[],uint256,uint256),(address,uint256)[],address,bytes)")
    );

    address internal borrower;
    address internal lender = address(0x1E4DE2);
    PoolKey internal wethKey;

    /// @dev Everything an ERC-20 addition may move, read in one place.
    struct Balances {
        uint256 borrowerWeth;
        uint256 borrowerUsdg;
        uint256 marketWeth;
        uint256 marketUsdg;
        uint256 positionManagerWeth;
        uint256 positionManagerUsdg;
        uint256 poolManagerWeth;
        uint256 poolManagerUsdg;
    }

    function setUp() public override {
        super.setUp();

        borrower = vm.addr(BORROWER_PK);
        vm.label(borrower, "borrower");
        wethKey = _keyOf(Fixtures.POS_WETH_USDG_WIDE_IN_RANGE);

        // The borrower's one-time Permit2 setup, which a wallet does once per token.
        deal(RobinhoodChain.WETH, borrower, WETH_BUDGET);
        deal(RobinhoodChain.USDG, borrower, USDG_BUDGET);
        vm.startPrank(borrower);
        IERC20(RobinhoodChain.WETH).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IERC20(RobinhoodChain.USDG).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        vm.stopPrank();

        deal(RobinhoodChain.USDG, lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        IERC20(RobinhoodChain.USDG).approve(address(market), LENDER_DEPOSIT);
        market.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();
    }

    /* --------------------------------- happy path ----------------------------- */

    /// @notice The position grows by exactly the liquidity asked for, stays in custody under the
    ///         same record, and says so with its pool indexed.
    function test_addsLiquidityToTheRecordedPosition() public {
        uint256 tokenId = _depositFresh(wethKey);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);

        // Signed first: reading Permit2's domain is a call, and would otherwise be the one the
        // expectation below is checked against.
        vm.expectEmit(true, true, true, true, address(market));
        emit FarmentaMarket.LiquidityChanged(tokenId, wethKey.toId(), int256(uint256(LIQUIDITY)));
        vm.prank(borrower);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);

        assertEq(positionManager.getPositionLiquidity(tokenId), 2 * LIQUIDITY, "liquidity was not added");
        assertEq(nft.ownerOf(tokenId), address(market), "the position left custody");
        assertEq(market.loanOf(tokenId).owner, borrower, "the record changed hands");
    }

    /// @notice The borrower pays exactly what the pool took, and neither the market nor
    ///         PositionManager keeps anything.
    /// @dev Each leg is sent at its maximum and the rest is swept back. The market's USDG is
    ///      lenders' money and must not move at all. `SWEEP` hands over PositionManager's whole
    ///      balance, so anything already stranded there reaches the borrower too; the
    ///      borrower's side is measured net of it.
    function test_borrowerPaysExactlyWhatThePoolTook() public {
        uint256 tokenId = _depositFresh(wethKey);

        Balances memory before = _balances();
        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);
        Balances memory afterIncrease = _balances();

        uint256 wethSpent = afterIncrease.poolManagerWeth - before.poolManagerWeth;
        uint256 usdgSpent = afterIncrease.poolManagerUsdg - before.poolManagerUsdg;
        assertGt(wethSpent, 0, "an in-range addition costs WETH");
        assertGt(usdgSpent, 0, "an in-range addition costs USDG");
        assertLt(wethSpent, WETH_BUDGET, "the WETH maximum should leave change");
        assertLt(usdgSpent, USDG_BUDGET, "the USDG maximum should leave change");

        assertEq(
            before.borrowerWeth - afterIncrease.borrowerWeth,
            wethSpent - before.positionManagerWeth,
            "borrower paid other than the WETH cost"
        );
        assertEq(
            before.borrowerUsdg - afterIncrease.borrowerUsdg,
            usdgSpent - before.positionManagerUsdg,
            "borrower paid other than the USDG cost"
        );
        assertEq(afterIncrease.marketWeth, before.marketWeth, "WETH was left in the market");
        assertEq(afterIncrease.marketUsdg, before.marketUsdg, "lenders' USDG moved");
        assertEq(afterIncrease.positionManagerWeth, 0, "WETH was left in PositionManager");
        assertEq(afterIncrease.positionManagerUsdg, 0, "USDG was left in PositionManager");
    }

    /// @notice A borrower close to liquidation strengthens the position by adding to it.
    /// @dev The case the function exists for. The position borrows its maximum, then ETH falls
    ///      until its health factor is under 1.05 while still above 1. Adding liquidity must go
    ///      through with no health-factor gate in the way, and leave the health factor higher.
    function test_raisesTheHealthFactorOfAnIndebtedPosition() public {
        uint256 tokenId = _depositFresh(wethKey);
        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);

        uint256 price = ETH_AT_POOL_SPOT;
        for (uint256 i; i < 100 && lens.healthFactor(tokenId) >= 1.05e18; ++i) {
            price = price * 995 / 1000;
            oracle.set(Currency.wrap(RobinhoodChain.WETH), price, 18);
        }
        uint256 healthBefore = lens.healthFactor(tokenId);
        assertLt(healthBefore, 1.05e18, "setup: the health factor should be under 1.05");
        assertGe(healthBefore, 1e18, "setup: the position should still be healthy");
        uint256 debtBefore = market.debtOf(tokenId);

        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);

        assertGt(lens.healthFactor(tokenId), healthBefore, "adding liquidity did not raise the health factor");
        assertEq(market.debtOf(tokenId), debtBefore, "adding liquidity changed the debt");
    }

    /// @notice The market grants no allowance to anyone, on either layer.
    /// @dev This replaces the ticket's approval-order regression test. `mintAndDeposit` settles
    ///      from the market and so needs token → Permit2 → PositionManager approvals; this path
    ///      pays PositionManager directly and needs none. An allowance appearing here would mean
    ///      the market became a payer again — the design that let a hook redeem at a price the
    ///      borrower's tokens had inflated.
    function test_grantsNoAllowance() public {
        uint256 tokenId = _depositFresh(wethKey);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);

        vm.expectCall(RobinhoodChain.PERMIT2, abi.encodeWithSelector(IAllowanceTransfer.approve.selector), 0);
        vm.expectCall(RobinhoodChain.WETH, abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.expectCall(RobinhoodChain.USDG, abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.prank(borrower);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);

        for (uint256 i; i < 2; ++i) {
            address token = i == 0 ? RobinhoodChain.WETH : RobinhoodChain.USDG;
            assertEq(IERC20(token).allowance(address(market), RobinhoodChain.PERMIT2), 0, "token -> Permit2 allowance");
            (uint160 allowed,,) = IAllowanceTransfer(RobinhoodChain.PERMIT2)
                .allowance(address(market), token, RobinhoodChain.POSITION_MANAGER);
            assertEq(allowed, 0, "Permit2 -> PositionManager allowance");
        }
    }

    /* --------------------------------- native ETH ----------------------------- */

    /// @notice A native-ETH pool spends from `msg.value` and sends the rest back, and the
    ///         position's uncollected fees go toward the cost.
    /// @dev The ~$11-of-fees fixture, doubled. ETH is currency0 and never touches Permit2:
    ///      PositionManager settles it out of the value forwarded and sweeps the rest to the
    ///      borrower. The fees the addition realises are held by PoolManager already, so what it
    ///      gains is the cost net of them, and that is what the borrower must be down by.
    function test_nativePoolSpendsEthAndReturnsTheRest() public {
        uint256 tokenId = _depositFixture(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 ethBudget = 1 ether;
        vm.deal(borrower, ethBudget);

        uint256 borrowerEth = borrower.balance;
        uint256 marketEth = address(market).balance;
        uint256 strayEth = RobinhoodChain.POSITION_MANAGER.balance;
        uint256 poolManagerEth = RobinhoodChain.POOL_MANAGER.balance;
        Balances memory before = _balances();

        _increase(tokenId, liquidity, ethBudget, USDG_BUDGET, 0);

        uint256 ethSpent = RobinhoodChain.POOL_MANAGER.balance - poolManagerEth;
        assertGt(ethSpent, 0, "an in-range addition costs ETH");
        assertLt(ethSpent, ethBudget, "the ETH maximum should leave change");
        assertEq(borrower.balance, borrowerEth - ethSpent + strayEth, "borrower paid other than the ETH cost");
        assertEq(RobinhoodChain.POSITION_MANAGER.balance, 0, "ETH was left in PositionManager");
        assertEq(address(market).balance, marketEth, "ETH reached the market");

        Balances memory afterIncrease = _balances();
        uint256 usdgSpent = afterIncrease.poolManagerUsdg - before.poolManagerUsdg;
        assertGt(usdgSpent, 0, "an in-range addition costs USDG");
        assertEq(
            before.borrowerUsdg - afterIncrease.borrowerUsdg,
            usdgSpent - before.positionManagerUsdg,
            "borrower paid other than the USDG cost"
        );
        assertEq(afterIncrease.marketUsdg, before.marketUsdg, "lenders' USDG moved");
        assertEq(positionManager.getPositionLiquidity(tokenId), 2 * liquidity, "liquidity was not added");
    }

    /// @notice §4.1 v0.26: the borrow asset leaves first, so a borrower that is a contract already
    ///         holds its USDG change when the ETH change first runs its code.
    /// @dev Swept in pool order, the ETH (`currency0`) would go first, and the contract would see
    ///      none of its USDG change: the whole USDG maximum was sent to PositionManager.
    function test_theUsdgChangeLeavesBeforeTheEth() public {
        ContractBorrower caller = new ContractBorrower(market);
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        // Read before the prank: an external call in the argument list would spend it.
        address holder = nft.ownerOf(tokenId);
        vm.prank(holder);
        nft.transferFrom(holder, address(caller), tokenId);
        caller.deposit(tokenId);
        caller.approve(RobinhoodChain.USDG, RobinhoodChain.PERMIT2);
        deal(RobinhoodChain.USDG, address(caller), USDG_BUDGET);
        vm.deal(address(this), 1 ether);

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            _permitFor(_keyOf(tokenId), 1 ether, USDG_BUDGET, 0, block.timestamp + 1 hours);
        caller.increase{value: 1 ether}(tokenId, liquidity, uint128(1 ether), uint128(USDG_BUDGET), permit);

        uint256 usdgChange = IERC20(RobinhoodChain.USDG).balanceOf(address(caller));
        assertGt(usdgChange, 0, "the USDG maximum should leave change");
        assertGt(address(caller).balance, 0, "the ETH maximum should leave change");
        assertEq(caller.usdgOnEthArrival(), usdgChange, "the USDG change had not arrived when the ETH did");
    }

    /// @notice An ETH leg that would cost more than `amount0Max` reverts, and the ETH comes back.
    function test_nativeCostAboveTheEthMaximumReverts() public {
        uint256 tokenId = _depositFixture(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        PoolKey memory ethKey = _keyOf(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        vm.deal(borrower, 1);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(ethKey, 1, USDG_BUDGET, 0);

        vm.prank(borrower);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        market.increaseLiquidity{value: 1}(tokenId, liquidity, 1, uint128(USDG_BUDGET), permit, signature);

        assertEq(borrower.balance, 1, "a refused addition kept the borrower's ETH");
    }

    /// @notice The ETH sent must be exactly the ETH maximum for a native pool, and nothing for an
    ///         ERC-20 pair.
    function test_valueMustMatchTheEthLeg() public {
        uint256 ethId = _depositFixture(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        uint256 wethId = _depositFresh(wethKey);
        vm.deal(borrower, 2 ether);

        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(_keyOf(ethId), 1 ether, USDG_BUDGET, 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NativeValueMismatch.selector, 1 ether, 1 ether - 1));
        market.increaseLiquidity{value: 1 ether - 1}(
            ethId, LIQUIDITY, uint128(1 ether), uint128(USDG_BUDGET), permit, signature
        );

        (permit, signature) = _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NativeValueMismatch.selector, 0, 1));
        market.increaseLiquidity{value: 1}(
            wethId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature
        );
    }

    /* ---------------------------------- refusals ------------------------------ */

    /// @notice An addition that would cost more than either maximum reverts.
    function test_costAboveEitherMaximumReverts() public {
        uint256 tokenId = _depositFresh(wethKey);

        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, 1, USDG_BUDGET, 0);
        vm.prank(borrower);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        market.increaseLiquidity(tokenId, LIQUIDITY, 1, uint128(USDG_BUDGET), permit, signature);

        (permit, signature) = _signedPermit(wethKey, WETH_BUDGET, 1, 0);
        vm.prank(borrower);
        vm.expectPartialRevert(SlippageCheck.MaximumAmountExceeded.selector);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), 1, permit, signature);
    }

    function test_expiredPermitReverts() public {
        uint256 tokenId = _depositFresh(wethKey);
        uint256 deadline = block.timestamp - 1;
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            _permitFor(wethKey, WETH_BUDGET, USDG_BUDGET, 0, deadline);
        bytes memory signature = _sign(BORROWER_PK, permit);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(SIGNATURE_EXPIRED, deadline));
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice A permit adds once. Replaying it reverts, even with the tokens to pay again.
    function test_replayedPermitReverts() public {
        uint256 tokenId = _depositFresh(wethKey);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);

        vm.prank(borrower);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);

        // Topped back up, so the only thing wrong with the second attempt is the nonce.
        deal(RobinhoodChain.WETH, borrower, WETH_BUDGET);
        deal(RobinhoodChain.USDG, borrower, USDG_BUDGET);

        vm.prank(borrower);
        vm.expectRevert(INVALID_NONCE);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice The permit must list the pool's currencies, in pool order.
    function test_permitForOtherCurrenciesReverts() public {
        uint256 tokenId = _depositFresh(wethKey);
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            _permitFor(wethKey, WETH_BUDGET, USDG_BUDGET, 0, block.timestamp + 1 hours);
        (permit.permitted[0], permit.permitted[1]) = (permit.permitted[1], permit.permitted[0]);
        bytes memory signature = _sign(BORROWER_PK, permit);

        vm.prank(borrower);
        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice Only the address a position is recorded to may add to it.
    /// @dev A broadcast permit is public, but it cannot be spent here by anyone else: the
    ///      record is checked before Permit2 is called, and Permit2 would refuse the signer too.
    function test_onlyTheDepositorMayAdd() public {
        uint256 tokenId = _depositFresh(wethKey);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotTheDepositor.selector, tokenId, borrower));
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice A frozen pool takes no new capital, and the refusal comes before any token moves.
    /// @dev §6.5 names `increaseLiquidity` among what delisting stops. Permit2 is never called:
    ///      the policy check runs first, which is what keeps a refusal cheap and legible.
    function test_frozenPoolRevertsBeforeAnyTokenMoves() public {
        uint256 tokenId = _depositFresh(wethKey);
        vm.prank(owner);
        policy.setFrozen(wethKey.toId(), true);
        _assertRefusedBeforeAnyTokenMoves(
            tokenId, abi.encodeWithSelector(CollateralPolicy.PoolFrozenForNewPositions.selector, wethKey.toId())
        );
    }

    /// @notice A token disabled since the position was deposited closes its pools to additions.
    function test_disabledTokenReverts() public {
        uint256 tokenId = _depositFresh(wethKey);
        vm.prank(owner);
        policy.setTokenConfig(
            Currency.wrap(RobinhoodChain.WETH), false, ICollateralPolicy.Tier.BLUE_CHIP, 18, address(1)
        );
        _assertRefusedBeforeAnyTokenMoves(
            tokenId,
            abi.encodeWithSelector(CollateralPolicy.TokenNotEnabled.selector, Currency.wrap(RobinhoodChain.WETH))
        );
    }

    /// @notice A hook taken off the allowlist since the position was deposited closes its pool
    ///         to additions.
    /// @dev The hook carries only the `afterRemoveLiquidity` bit and has no code: adding
    ///      liquidity never calls it, and that one bit is all the policy reads.
    function test_revokedHookReverts() public {
        address hook = address((uint160(0xF00D) << 144) | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        vm.prank(owner);
        policy.setHookAllowlist(hook, true);
        uint256 tokenId = _depositFresh(_initPool(hook));
        vm.prank(owner);
        policy.setHookAllowlist(hook, false);

        _assertRefusedBeforeAnyTokenMoves(
            tokenId, abi.encodeWithSelector(CollateralPolicy.HookNotPermitted.selector, hook)
        );
    }

    /* ------------------------------ outbound calls ---------------------------- */

    /// @notice A hook that redeems its vault shares from inside the addition gets exactly what
    ///         they were worth, and the borrower pays nothing for it.
    /// @dev §4.1 v0.26: every market function that calls out must survive a vault exit from
    ///      inside the call. The hook here passes the §6.1 bit check, which is about removing
    ///      liquidity, not adding it. Had the borrower's tokens been pulled into the market,
    ///      they would count toward `totalAssets` while the hook ran: measured on
    ///      `mintAndDeposit`, shares worth 20,000 USDG redeemed for 48,571 and the borrower's
    ///      change paid the difference. Here the tokens never reach the market, so the share
    ///      price the hook sees is the one everyone else sees.
    function test_aRedeemFromInsideTheHookGainsNothing() public {
        address hook = address((uint160(0xDEF1) << 144) | Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        deployCodeTo("VaultRedeemingHook.sol:VaultRedeemingHook", abi.encode(market), hook);
        PoolKey memory key = _initPool(hook);
        uint256 tokenId = _depositFresh(key);

        deal(RobinhoodChain.USDG, hook, 20_000e6);
        VaultRedeemingHook(hook).deposit(20_000e6);
        uint256 fair = market.previewRedeem(market.balanceOf(hook));

        Balances memory before = _balances();
        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);
        Balances memory afterIncrease = _balances();

        uint256 redeemed = VaultRedeemingHook(hook).redeemed();
        assertGt(redeemed, 0, "the redeem must actually run inside the addition");
        assertLe(redeemed, fair, "a share redeemed mid-addition is worth more than before it");

        uint256 usdgSpent = afterIncrease.poolManagerUsdg - before.poolManagerUsdg;
        assertEq(
            before.borrowerUsdg - afterIncrease.borrowerUsdg,
            usdgSpent - before.positionManagerUsdg,
            "the borrower paid for the redemption"
        );
        assertEq(afterIncrease.marketUsdg, before.marketUsdg - redeemed, "the market paid out more than the redeem");
    }

    /* --------------------------------- helpers -------------------------------- */

    /// @dev A refused addition calls Permit2 for nothing, and moves no token.
    function _assertRefusedBeforeAnyTokenMoves(
        uint256 tokenId,
        bytes memory reason
    ) internal {
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(_keyOf(tokenId), WETH_BUDGET, USDG_BUDGET, 0);
        Balances memory before = _balances();

        vm.expectCall(RobinhoodChain.PERMIT2, abi.encodePacked(PERMIT_BATCH_TRANSFER_FROM), 0);
        vm.prank(borrower);
        vm.expectRevert(reason);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);

        Balances memory now_ = _balances();
        assertEq(now_.borrowerWeth, before.borrowerWeth, "the borrower's WETH moved");
        assertEq(now_.borrowerUsdg, before.borrowerUsdg, "the borrower's USDG moved");
        assertEq(now_.marketUsdg, before.marketUsdg, "the market's USDG moved");
    }

    /// @dev A fresh WETH/USDG-pair position ten spacings either side of the oracle price, minted
    ///      outside the market, handed to the borrower and deposited by them. The pool is listed
    ///      first. Deposited rather than minted in, so no earlier `mintAndDeposit` has left
    ///      approvals standing on the market.
    function _depositFresh(
        PoolKey memory key
    ) internal returns (uint256 tokenId) {
        _listPool(key, TierPresets.blueChip().minPositionUsd, 0);
        int24 mid = _alignedOracleTick(key.tickSpacing);

        _fundAndApprove(key, WETH_BUDGET, USDG_BUDGET);
        tokenId = _mint(key, mid - 10 * key.tickSpacing, mid + 10 * key.tickSpacing, LIQUIDITY);
        nft.transferFrom(address(this), borrower, tokenId);

        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    /// @dev A real position, moved to the borrower and deposited by them after its pool is listed.
    function _depositFixture(
        uint256 tokenId
    ) internal returns (uint256) {
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        // Read before the prank: an external call in the argument list would spend it.
        address holder = nft.ownerOf(tokenId);
        vm.prank(holder);
        nft.transferFrom(holder, borrower, tokenId);

        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();
        return tokenId;
    }

    /// @dev Signs, then submits as the borrower, sending the ETH maximum for a native pool.
    function _increase(
        uint256 tokenId,
        uint128 liquidity,
        uint256 max0,
        uint256 max1,
        uint256 nonce
    ) internal {
        PoolKey memory key = _keyOf(tokenId);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(key, max0, max1, nonce);
        uint256 value = key.currency0.isAddressZero() ? max0 : 0;

        vm.prank(borrower);
        // Safe: every maximum a test passes is a budget of at most 100,000 tokens, far below
        // 2^128 in either token's base units.
        // forge-lint: disable-next-line(unsafe-typecast)
        market.increaseLiquidity{value: value}(tokenId, liquidity, uint128(max0), uint128(max1), permit, signature);
    }

    /// @dev The permit a wallet would ask the borrower to sign: each ERC-20 leg at its maximum,
    ///      valid for an hour.
    function _signedPermit(
        PoolKey memory key,
        uint256 max0,
        uint256 max1,
        uint256 nonce
    ) internal view returns (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) {
        permit = _permitFor(key, max0, max1, nonce, block.timestamp + 1 hours);
        signature = _sign(BORROWER_PK, permit);
    }

    function _permitFor(
        PoolKey memory key,
        uint256 max0,
        uint256 max1,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (ISignatureTransfer.PermitBatchTransferFrom memory permit) {
        if (key.currency0.isAddressZero()) {
            permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
            permit.permitted[0] = _permission(Currency.unwrap(key.currency1), max1);
        } else {
            permit.permitted = new ISignatureTransfer.TokenPermissions[](2);
            permit.permitted[0] = _permission(Currency.unwrap(key.currency0), max0);
            permit.permitted[1] = _permission(Currency.unwrap(key.currency1), max1);
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
        b.positionManagerWeth = weth.balanceOf(RobinhoodChain.POSITION_MANAGER);
        b.positionManagerUsdg = usdg.balanceOf(RobinhoodChain.POSITION_MANAGER);
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
