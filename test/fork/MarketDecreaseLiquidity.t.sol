// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {SlippageCheck} from "@uniswap/v4-periphery/src/libraries/SlippageCheck.sol";

import {CollateralPolicy} from "../../src/CollateralPolicy.sol";
import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "../../src/interfaces/IPositionValuer.sol";
import {TierPresets} from "../../src/libraries/TierPresets.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";
import {ContractBorrower} from "../mocks/ContractBorrower.sol";
import {RedeemingRecipient} from "../mocks/RedeemingRecipient.sol";

/// @notice `decreaseLiquidity` (§4.1, FAR-8) against a real position on the pinned block.
/// @dev The main fixture is native ETH behind a live dynamic-fee hook and holds fees on both legs,
///      so the ETH leg, the hook running inside the removal, and the fees that leave with the
///      principal are all exercised by the same position.
///
///      What a removal should pay and leave behind is never recomputed here. `_probe` makes the
///      same removal straight on PositionManager, as the market (which owns the NFT), with a
///      plain `TAKE_PAIR`, reads the result, and rolls the chain back. The market's own path is then
///      held to those figures.
contract MarketDecreaseLiquidityForkTest is MarketForkTest {
    /// @dev What `_probe` found: what the removal pays, and the position it leaves.
    struct Probe {
        uint256 out0;
        uint256 out1;
        uint256 principalUsdLeft;
        uint256 healthFactorLeft;
    }

    address internal lender = address(0x1E4DE2);
    address internal recipient = makeAddr("recipient");

    uint256 internal tokenId;
    address internal borrower;
    uint128 internal liquidity;

    /// @dev Held rather than read through `market.asset()` inside a pranked statement, where the
    ///      external call would spend the prank.
    IERC20 internal usdg;

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        borrower = nft.ownerOf(tokenId);
        liquidity = positionManager.getPositionLiquidity(tokenId);
        usdg = IERC20(market.asset());
    }

    /* -------------------------------- the removal ----------------------------- */

    /// @notice With nothing owed, half the liquidity leaves as its principal plus every fee, and half
    ///         stays.
    /// @dev Both legs come straight from PoolManager, so neither the market's ETH nor its USDG may
    ///      move: `rescueUnaccountedEth` sweeps whatever ETH is there, and is only sound while no
    ///      path leaves any behind.
    function test_halfThePrincipalAndEveryFeeReachTheRecipient() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        assertGt(before.fees0, 0, "the fixture must hold ETH fees");
        assertGt(before.fees1, 0, "the fixture must hold USDG fees");
        uint128 half = liquidity / 2;
        Probe memory expected = _probe(tokenId, half);
        uint256 marketEth = address(market).balance;
        uint256 marketUsdg = usdg.balanceOf(address(market));

        vm.expectEmit(true, true, false, true, address(market));
        emit FarmentaMarket.LiquidityChanged(tokenId, _keyOf(tokenId).toId(), -int256(uint256(half)));
        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, half, 0, 0, recipient);

        assertEq(recipient.balance, expected.out0, "the ETH leg reaches the recipient");
        assertEq(usdg.balanceOf(recipient), expected.out1, "the USDG leg reaches the recipient");
        assertApproxEqRel(recipient.balance - before.fees0, before.amount0 / 2, 0.01e18, "half the ETH principal");
        assertApproxEqRel(
            usdg.balanceOf(recipient) - before.fees1, before.amount1 / 2, 0.01e18, "half the USDG principal"
        );

        IPositionValuer.Valuation memory left = valuer.value(tokenId);
        assertEq(left.liquidity, liquidity - half, "the other half stays");
        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity - half, "in PositionManager's books too");
        assertEq(left.fees0, 0, "every ETH fee left with the principal");
        assertEq(left.fees1, 0, "every USDG fee left with the principal");
        assertEq(address(market).balance, marketEth, "no ETH is left in the market");
        assertEq(usdg.balanceOf(address(market)), marketUsdg, "the removal never touches the market's cash");
        assertEq(nft.ownerOf(tokenId), address(market), "the position stays in custody");
    }

    /// @notice An ERC-20 pair pays both legs to `to` the same way.
    function test_bothErc20LegsReachTheRecipient() public {
        uint256 id = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        address holder = _deposit(id);
        uint128 half = positionManager.getPositionLiquidity(id) / 2;
        Probe memory expected = _probe(id, half);
        assertGt(expected.out0, 0, "the fixture must pay a WETH leg");
        assertGt(expected.out1, 0, "the fixture must pay a USDG leg");

        vm.prank(holder);
        market.decreaseLiquidity(id, half, 0, 0, recipient);

        assertEq(IERC20(RobinhoodChain.WETH).balanceOf(recipient), expected.out0, "the WETH leg reaches the recipient");
        assertEq(usdg.balanceOf(recipient), expected.out1, "the USDG leg reaches the recipient");
    }

    /// @notice Only the depositor may remove liquidity, and a refusal leaves the position whole.
    function test_onlyTheDepositorMayRemove() public {
        _deposit(tokenId);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.NotTheDepositor.selector, tokenId, borrower));
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, 0, stranger);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "the liquidity stays in the position");
    }

    /// @notice §4.1 v0.43: PositionManager is refused as a recipient. A payout made to it would sit in
    ///         its balance, where anyone takes it with `SWEEP`.
    function test_positionManagerIsRefusedAsTheRecipient() public {
        _deposit(tokenId);
        address pm = address(positionManager);

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(FarmentaMarket.InvalidRecipient.selector, pm));
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, 0, pm);
    }

    /// @notice Asking for more than the position holds is refused by name, not deep inside PoolManager.
    function test_moreThanThePositionHoldsIsRefusedByName() public {
        _deposit(tokenId);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(FarmentaMarket.LiquidityExceedsPosition.selector, tokenId, liquidity + 1, liquidity)
        );
        market.decreaseLiquidity(tokenId, liquidity + 1, 0, 0, recipient);
    }

    /// @notice §6.5: freezing a pool stops new risk, not a borrower taking its own liquidity out.
    /// @dev With debt outstanding, so the health check and its price gates run on a frozen pool too.
    function test_freezingThePoolDoesNotStopTheRemoval() public {
        _openLoan(20e6);
        // Read before the prank: `_keyOf` is an external call and would spend it.
        PoolId poolId = _keyOf(tokenId).toId();
        vm.prank(owner);
        policy.setFrozen(poolId, true);
        Probe memory expected = _probe(tokenId, liquidity / 4);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 4, 0, 0, recipient);

        assertEq(usdg.balanceOf(recipient), expected.out1, "a frozen pool's liquidity can still be removed");
    }

    /* --------------------------------- slippage ------------------------------- */

    /// @notice A minimum the pool meets, to the unit, passes.
    /// @dev The minimums are the slice's principal: what the probe paid, less the fees that came with
    ///      it.
    function test_aMinimumThePoolMeetsExactlyPasses() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        Probe memory expected = _probe(tokenId, liquidity / 2);
        uint128 principal0 = uint128(expected.out0 - before.fees0);
        uint128 principal1 = uint128(expected.out1 - before.fees1);

        vm.prank(borrower);
        market.decreaseLiquidity(tokenId, liquidity / 2, principal0, principal1, recipient);

        assertEq(recipient.balance, expected.out0, "the removal went through");
    }

    /// @notice A minimum one unit above what the pool returns reverts, and the fees paid out alongside
    ///         do not make up the difference.
    /// @dev PositionManager holds the minimums against the principal alone. The fixture's fees are far
    ///      more than one unit on either leg, so a check that counted them would let both of these
    ///      through.
    function test_aMinimumAboveThePrincipalRevertsWhateverTheFees() public {
        _deposit(tokenId);
        IPositionValuer.Valuation memory before = valuer.value(tokenId);
        Probe memory expected = _probe(tokenId, liquidity / 2);
        uint128 principal0 = uint128(expected.out0 - before.fees0);
        uint128 principal1 = uint128(expected.out1 - before.fees1);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, principal0 + 1, principal0)
        );
        market.decreaseLiquidity(tokenId, liquidity / 2, principal0 + 1, 0, recipient);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, principal1 + 1, principal1)
        );
        market.decreaseLiquidity(tokenId, liquidity / 2, 0, principal1 + 1, recipient);

        assertEq(positionManager.getPositionLiquidity(tokenId), liquidity, "the liquidity stays in the position");
    }

    /* --------------------------------- helpers -------------------------------- */

    function _deposit(
        uint256 id
    ) private returns (address holder) {
        return _depositWithHaircut(id, 0);
    }

    function _depositWithHaircut(
        uint256 id,
        uint16 removeHaircutBps
    ) private returns (address holder) {
        _listPoolOf(id, 50e18, removeHaircutBps);
        holder = nft.ownerOf(id);
        vm.startPrank(holder);
        nft.approve(address(market), id);
        market.depositCollateral(id);
        vm.stopPrank();
    }

    function _lend(
        uint256 amount
    ) private {
        deal(address(usdg), lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(market), type(uint256).max);
        market.deposit(amount, lender);
        vm.stopPrank();
    }

    function _openLoan(
        uint256 amount
    ) private {
        _deposit(tokenId);
        _lend(300e6);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
    }

    /// @dev Removes `amount` from `id` straight on PositionManager, as the market that owns it, and
    ///      reports what that paid and left behind. The chain is rolled back afterwards. It shares no
    ///      code with the market's path: a `TAKE_PAIR` to a fresh address, and the lens for the health
    ///      factor.
    function _probe(
        uint256 id,
        uint128 amount
    ) private returns (Probe memory probe) {
        PoolKey memory key = _keyOf(id);
        address sink = makeAddr("probe");
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(amount), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, sink);
        bytes memory call_ =
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params);

        uint256 snapshot = vm.snapshotState();
        vm.prank(address(market));
        positionManager.modifyLiquidities(call_, block.timestamp);
        probe.out0 = key.currency0.balanceOf(sink);
        probe.out1 = key.currency1.balanceOf(sink);
        probe.principalUsdLeft = valuer.value(id).principalUsd;
        probe.healthFactorLeft = lens.healthFactor(id);
        vm.revertToState(snapshot);
    }

    /// @dev Donates to the position's pool so that `id`'s own share is about `amount0` and
    ///      `amount1`. Each leg is scaled by the pool's liquidity over the position's.
    function _donateFees(
        uint256 id,
        uint256 amount0,
        uint256 amount1
    ) private {
        PoolKey memory key = _keyOf(id);
        uint256 poolLiquidity = stateView.getLiquidity(key.toId());
        uint256 positionLiquidity = positionManager.getPositionLiquidity(id);
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

    /// @dev The fixture listed and deposited on a meme market, with a lender behind it. Native ETH is
    ///      re-tiered as meme first, which makes the pool meme (§6.1 takes the higher tier).
    function _openMemeMarket() private returns (FarmentaMarket memeMarket) {
        vm.prank(owner);
        policy.setTokenConfig(Currency.wrap(RobinhoodChain.NATIVE), true, ICollateralPolicy.Tier.MEME, 18, address(1));
        memeMarket = _deployMarket(ICollateralPolicy.Tier.MEME);

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

        vm.startPrank(borrower);
        nft.approve(address(memeMarket), tokenId);
        memeMarket.depositCollateral(tokenId);
        vm.stopPrank();

        deal(address(usdg), lender, 300e6);
        vm.startPrank(lender);
        usdg.approve(address(memeMarket), type(uint256).max);
        memeMarket.deposit(300e6, lender);
        vm.stopPrank();
    }
}
