// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
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
    /// @dev The case the function exists for. The position borrows its maximum, then interest
    ///      carries its health factor under 1.05 while it is still above 1. Adding liquidity must
    ///      go through and leave the health factor higher.
    ///
    ///      Interest, not a price move: since v0.47 an indebted addition runs §5.2's borrow price
    ///      gates, and dropping the oracle would refuse it on the ±2% spot gate instead
    ///      (`test_anIndebtedAdditionRunsTheSpotGate`).
    function test_raisesTheHealthFactorOfAnIndebtedPosition() public {
        uint256 tokenId = _depositFresh(wethKey);
        uint256 amount = lens.maxBorrow(tokenId);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);

        _ageUntilHealthFactorBelow(tokenId, 1.05e18);
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

    /* ----------------------------- the fee claim ------------------------------ */

    /// @notice A position whose fees exceed what the addition costs on a leg can still be added to.
    /// @dev The case v0.47 was decided for. `POS_WETH_USDG_ABOVE_RANGE` is all USDG with fees
    ///      uncollected on both legs, so the WETH leg costs nothing while holding fees:
    ///      `INCREASE_LIQUIDITY` would credit them and `SETTLE` would refuse the positive delta
    ///      (`DeltaNotNegative`), at any size. Claiming first is what makes this go through.
    function test_anOutOfRangePositionWithFeesCanStillBeAddedTo() public {
        uint256 tokenId = _depositFixture(Fixtures.POS_WETH_USDG_ABOVE_RANGE);
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        assertGt(valuation.fees0, 0, "the fixture must hold fees on the leg the addition does not spend");
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 wethBefore = IERC20(RobinhoodChain.WETH).balanceOf(borrower);

        _increase(tokenId, liquidity, WETH_BUDGET, USDG_BUDGET, 0);

        assertEq(positionManager.getPositionLiquidity(tokenId), 2 * liquidity, "liquidity was not added");
        assertEq(
            IERC20(RobinhoodChain.WETH).balanceOf(borrower) - wethBefore,
            valuation.fees0,
            "the fees on the unspent leg did not reach the borrower"
        );
        assertEq(valuer.value(tokenId).fees0, 0, "the position still holds fees");
    }

    /// @notice With debt outstanding, the claim may not leave the position under water.
    /// @dev The claim takes the counted fees out of the collateral value (capped at 10% of
    ///      principal, §6.2), so a maximum borrow plus a small addition ends below 1. §7's
    ///      post-condition is checked after the whole action, as `collectFees` checks it (v0.40).
    function test_anAdditionThatWouldLeaveThePositionUnhealthyReverts() public {
        uint256 tokenId = _openIndebtedFixture(type(uint256).max);
        _ageUntilHealthFactorBelow(tokenId, 1.05e18);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId) / 100;
        vm.deal(borrower, 1 ether);

        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(_keyOf(tokenId), 0.1 ether, USDG_BUDGET, 0);
        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.PositionWouldBeUnhealthy.selector);
        market.increaseLiquidity{value: 0.1 ether}(
            tokenId, liquidity, 0.1 ether, uint128(USDG_BUDGET), permit, signature
        );
    }

    /// @notice An indebted addition runs §5.2's USDG band, which applies to every tier.
    function test_anIndebtedAdditionRunsTheUsdgBand() public {
        uint256 tokenId = _depositFresh(wethKey);
        _borrow(tokenId, 10e6);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);

        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.UsdgPriceOutOfBounds.selector, 0.96e18));
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice An indebted addition on a blue-chip market runs the ±2% spot gate too.
    /// @dev The cost of v0.47 that the PR names: a pool far from the oracle refuses the addition,
    ///      even though the addition itself only adds value.
    function test_anIndebtedAdditionRunsTheSpotGate() public {
        uint256 tokenId = _depositFresh(wethKey);
        _borrow(tokenId, 10e6);
        oracle.set(Currency.wrap(RobinhoodChain.WETH), ETH_AT_POOL_SPOT * 90 / 100, 18);

        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);
        vm.prank(borrower);
        vm.expectPartialRevert(FarmentaMarket.SpotPriceDeviation.selector);
        market.increaseLiquidity(tokenId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice A position owing nothing passes neither gate, because there is no debt to protect.
    function test_anAdditionWithoutDebtRunsNoGate() public {
        uint256 tokenId = _depositFresh(wethKey);
        oracle.set(Currency.wrap(RobinhoodChain.USDG), 0.96e18, RobinhoodChain.USDG_DECIMALS);

        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);

        assertEq(positionManager.getPositionLiquidity(tokenId), 2 * LIQUIDITY, "liquidity was not added");
    }

    /// @notice The addition accrues before it reads anything.
    /// @dev The tiket asks for `accrue()` first. Without it the health check below would price the
    ///      position against a stale index.
    function test_theAdditionAccruesFirst() public {
        uint256 tokenId = _depositFresh(wethKey);
        _borrow(tokenId, 100e6);
        _drainLenderCash();
        vm.warp(block.timestamp + 30 days);
        uint256 indexBefore = market.borrowIndex();

        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);

        assertGt(market.borrowIndex(), indexBefore, "the addition did not accrue first");
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

        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        assertGt(valuation.fees0, 0, "the fixture must hold ETH fees");
        assertGt(valuation.fees1, 0, "the fixture must hold USDG fees");
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
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        assertGt(valuation.fees0, 0, "the fixture must hold ETH fees");
        assertGt(valuation.fees1, 0, "the fixture must hold USDG fees");
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            _permitFor(_keyOf(tokenId), 1 ether, USDG_BUDGET, 0, block.timestamp + 1 hours);
        caller.increase{value: 1 ether}(tokenId, liquidity, uint128(1 ether), uint128(USDG_BUDGET), permit);

        // ETH arrives twice, and each arrival pins one order: the fee `TAKE` first, the `SWEEP` of
        // the change second. Reading only the last one would leave the claim's order untested.
        assertEq(caller.ethArrivals(), 2, "the fee TAKE and the SWEEP should each have paid ETH");
        assertEq(caller.usdgOnFirstEthArrival(), valuation.fees1, "the USDG fees had not arrived when the ETH fees did");

        uint256 usdgChange = IERC20(RobinhoodChain.USDG).balanceOf(address(caller));
        assertGt(usdgChange, valuation.fees1, "the USDG maximum should leave change");
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

    /* --------------------------------- meme market ---------------------------- */

    /// @notice §5.3: every market transaction touching a meme pool records an observation first, and
    ///         an addition is one of them.
    function test_aMemeAdditionRecordsAnObservationFirst() public {
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _openMemeMarket(tokenId);
        PoolId poolId = _keyOf(tokenId).toId();
        uint256 records = oracle.recordCount(poolId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        vm.deal(borrower, 1 ether);

        _increase(tokenId, liquidity, 1 ether, USDG_BUDGET, 0);

        assertEq(oracle.recordCount(poolId), records + 1, "the addition recorded the pool once");
        assertEq(positionManager.getPositionLiquidity(tokenId), 2 * liquidity, "liquidity was not added");
    }

    /// @notice A blue-chip addition has no TWAP to feed, and pays nothing for one.
    function test_aBlueChipAdditionRecordsNothing() public {
        uint256 tokenId = _depositFresh(wethKey);

        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);

        assertEq(oracle.recordCount(wethKey.toId()), 0, "no observation for a blue-chip pool");
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

    /// @notice A zero addition is refused: that is a fee claim, and `collectFees` is its function.
    function test_zeroLiquidityReverts() public {
        uint256 tokenId = _depositFresh(wethKey);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory signature) =
            _signedPermit(wethKey, WETH_BUDGET, USDG_BUDGET, 0);

        vm.prank(borrower);
        vm.expectRevert(FarmentaMarket.ZeroLiquidity.selector);
        market.increaseLiquidity(tokenId, 0, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);
    }

    /// @notice The permit must carry one entry per ERC-20 leg: two for a pair, one for a native pool.
    /// @dev The count check guards the helper `mintAndDeposit` shares. A permit that is simply short
    ///      or long must be refused by name, not by an arithmetic panic further in.
    function test_permitMustCarryOneEntryPerErc20Leg() public {
        uint256 wethId = _depositFresh(wethKey);
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            _permitFor(wethKey, WETH_BUDGET, USDG_BUDGET, 0, block.timestamp + 1 hours);
        ISignatureTransfer.TokenPermissions[] memory one = new ISignatureTransfer.TokenPermissions[](1);
        one[0] = permit.permitted[0];
        permit.permitted = one;
        bytes memory signature = _sign(BORROWER_PK, permit);

        vm.prank(borrower);
        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.increaseLiquidity(wethId, LIQUIDITY, uint128(WETH_BUDGET), uint128(USDG_BUDGET), permit, signature);

        uint256 ethId = _depositFixture(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        vm.deal(borrower, 1 ether);
        permit = _permitFor(_keyOf(ethId), 1 ether, USDG_BUDGET, 0, block.timestamp + 1 hours);
        ISignatureTransfer.TokenPermissions[] memory two = new ISignatureTransfer.TokenPermissions[](2);
        (two[0], two[1]) = (permit.permitted[0], permit.permitted[0]);
        permit.permitted = two;
        signature = _sign(BORROWER_PK, permit);

        vm.prank(borrower);
        vm.expectRevert(FarmentaMarket.PermitDoesNotMatchPool.selector);
        market.increaseLiquidity{value: 1 ether}(
            ethId, LIQUIDITY, uint128(1 ether), uint128(USDG_BUDGET), permit, signature
        );
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

    /// @notice A caller that re-enters a guarded market function while the ETH is being paid out
    ///         gets nowhere, and takes its own addition down with it.
    /// @dev The guard on the wrapper, exercised where a contract caller first runs code: the `TAKE`
    ///      of the ETH fees. `repay` of zero is the call it makes, which succeeds if the guard is
    ///      gone. The ETH transfer reverting is what PoolManager reports.
    function test_aReentrantCallerIsRefused() public {
        ContractBorrower caller = new ContractBorrower(market);
        uint256 tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, TierPresets.blueChip().minPositionUsd);
        address holder = nft.ownerOf(tokenId);
        vm.prank(holder);
        nft.transferFrom(holder, address(caller), tokenId);
        caller.deposit(tokenId);
        caller.approve(RobinhoodChain.USDG, RobinhoodChain.PERMIT2);
        deal(RobinhoodChain.USDG, address(caller), USDG_BUDGET);
        vm.deal(address(this), 1 ether);
        caller.armReentry(tokenId);

        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        ISignatureTransfer.PermitBatchTransferFrom memory permit =
            _permitFor(_keyOf(tokenId), 1 ether, USDG_BUDGET, 0, block.timestamp + 1 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(caller),
                bytes4(0),
                abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
                abi.encodeWithSelector(CurrencyLibrary.NativeTransferFailed.selector)
            )
        );
        caller.increase{value: 1 ether}(tokenId, liquidity, uint128(1 ether), uint128(USDG_BUDGET), permit);
    }

    /// @notice Even with both approval layers standing, the market never pays for an addition.
    /// @dev A market that has ever run `mintAndDeposit` leaves `token → Permit2 → PositionManager`
    ///      at the maximum. `SETTLE` with `payerIsUser = true` would then draw the USDG leg from
    ///      lenders' cash through Permit2. Nothing here is a payer, so the balances do not move.
    function test_aStandingAllowanceStillDoesNotLetTheMarketPay() public {
        uint256 tokenId = _depositFresh(wethKey);
        vm.startPrank(address(market));
        IERC20(RobinhoodChain.WETH).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IERC20(RobinhoodChain.USDG).approve(RobinhoodChain.PERMIT2, type(uint256).max);
        IAllowanceTransfer(RobinhoodChain.PERMIT2)
            .approve(RobinhoodChain.WETH, RobinhoodChain.POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(RobinhoodChain.PERMIT2)
            .approve(RobinhoodChain.USDG, RobinhoodChain.POSITION_MANAGER, type(uint160).max, type(uint48).max);
        vm.stopPrank();

        Balances memory before = _balances();
        _increase(tokenId, LIQUIDITY, WETH_BUDGET, USDG_BUDGET, 0);
        Balances memory afterIncrease = _balances();

        assertEq(afterIncrease.marketUsdg, before.marketUsdg, "lenders' USDG paid for the addition");
        assertEq(afterIncrease.marketWeth, before.marketWeth, "the market's WETH paid for the addition");
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

    /// @dev Replaces `market` with a meme market holding `tokenId` as the borrower's collateral.
    ///      Native ETH is re-tiered as meme first, which makes the pool meme (§6.1 takes the higher
    ///      tier), and the pool is listed on the meme preset.
    function _openMemeMarket(
        uint256 tokenId
    ) internal {
        vm.prank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.MEME, 18, address(1));
        market = _deployMarket(ICollateralPolicy.Tier.MEME);

        PoolKey memory key = _keyOf(tokenId);
        TierPresets.Preset memory preset = TierPresets.meme();
        vm.prank(owner);
        policy.list(
            key,
            CollateralPolicy.ListingParams({
                maxLtvBps: preset.maxLtvBps,
                ltBps: preset.ltBps,
                liquidatorBonusBps: preset.minLiquidatorBonusBps,
                removeHaircutBps: 0,
                debtCapUsdg: preset.maxDebtCapUsdg,
                minPositionUsd: 50e18
            })
        );

        // Read before the prank: an external call in the argument list would spend it.
        address holder = nft.ownerOf(tokenId);
        vm.prank(holder);
        nft.transferFrom(holder, borrower, tokenId);
        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();
    }

    /// @dev The fixture deposited, its fees donated up to a third of its principal, and borrowed
    ///      against to `amount` (or the maximum). Enough fee value to matter: the health check
    ///      counts fees only up to 10% of principal (§6.2), and the claim takes all of it out.
    function _openIndebtedFixture(
        uint256 amount
    ) internal returns (uint256 tokenId) {
        tokenId = _depositFixture(Fixtures.POS_ETH_USDG_DYN_IN_RANGE);
        _donateFees(tokenId, 0, valuer.value(tokenId).principalUsd / 1e12 / 3);

        deal(RobinhoodChain.USDG, lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        IERC20(RobinhoodChain.USDG).approve(address(market), LENDER_DEPOSIT);
        market.deposit(LENDER_DEPOSIT, lender);
        vm.stopPrank();

        uint256 maximum = lens.maxBorrow(tokenId);
        _borrow(tokenId, amount > maximum ? maximum : amount);
    }

    /// @dev Interest carries the position under `target`, which leaves the oracle exactly where it
    ///      is. A price move would refuse the addition on §5.2's ±2% spot gate instead (v0.47), and
    ///      that is a different test. The lender's cash goes first: at the utilisation this suite
    ///      lends at, the blue-chip curve barely accrues at all.
    function _ageUntilHealthFactorBelow(
        uint256 tokenId,
        uint256 target
    ) internal {
        _drainLenderCash();
        for (uint256 i; i < 600 && lens.healthFactor(tokenId) >= target; ++i) {
            vm.warp(block.timestamp + 7 days);
            market.accrue();
        }
        assertLt(lens.healthFactor(tokenId), target, "setup: the health factor never fell far enough");
    }

    /// @dev Takes the lender's cash back out, so what is borrowed is most of what is left.
    function _drainLenderCash() internal {
        uint256 cash = market.maxWithdraw(lender);
        if (cash == 0) return;
        vm.prank(lender);
        market.withdraw(cash, lender, lender);
    }

    /// @dev Read before the prank: an external call in the argument list would spend it.
    function _borrow(
        uint256 tokenId,
        uint256 amount
    ) internal {
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
    }

    /// @dev Fees the position did not earn, donated into its pool so its share is `amount0`/
    ///      `amount1`. The fork holds no swaps, so this is the only way to a fee-rich position.
    function _donateFees(
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        PoolKey memory key = _keyOf(tokenId);
        uint256 poolLiquidity = stateView.getLiquidity(key.toId());
        uint256 positionLiquidity = positionManager.getPositionLiquidity(tokenId);
        uint256 donation0 = amount0 * poolLiquidity / positionLiquidity;
        uint256 donation1 = amount1 * poolLiquidity / positionLiquidity;

        PoolDonateTest donor = new PoolDonateTest(poolManager);
        uint256 value;
        if (key.currency0.isAddressZero()) {
            value = donation0;
            vm.deal(address(this), donation0);
        } else {
            deal(Currency.unwrap(key.currency0), address(this), donation0);
            IERC20(Currency.unwrap(key.currency0)).approve(address(donor), donation0);
        }
        deal(Currency.unwrap(key.currency1), address(this), donation1);
        IERC20(Currency.unwrap(key.currency1)).approve(address(donor), donation1);
        donor.donate{value: value}(key, donation0, donation1, "");
    }

    function _depositFixture(
        uint256 tokenId
    ) internal returns (uint256) {
        return _depositFixture(tokenId, TierPresets.blueChip().minPositionUsd);
    }

    /// @dev A real position, moved to the borrower and deposited by them after its pool is listed.
    function _depositFixture(
        uint256 tokenId,
        uint128 minPositionUsd
    ) internal returns (uint256) {
        _listPoolOf(tokenId, minPositionUsd);
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
