// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

import {FarmentaMarket} from "../../src/FarmentaMarket.sol";
import {MarketLens} from "../../src/MarketLens.sol";
import {ICollateralPolicy} from "../../src/interfaces/ICollateralPolicy.sol";
import {Fixtures} from "../base/Fixtures.sol";
import {MarketForkTest} from "../base/MarketForkTest.sol";

/// @notice Restricts invariant fuzzing to bounded lender and borrower actions.
contract MarketHandler is Test {
    FarmentaMarket internal immutable market;
    MarketLens internal immutable lens;
    IERC20 internal immutable usdg;
    uint256 internal immutable tokenId;
    /// @dev A second position that never borrows, so its removals are stopped by the minimum alone.
    ///      On the indebted one the borrow limit always binds first.
    uint256 internal immutable idleTokenId;
    address internal immutable idleHolder;
    address internal immutable borrower;
    address internal immutable lender;
    address internal immutable owner;
    /// @dev Ghost state is asserted by invariant functions because with `fail_on_revert = false`,
    ///      an assert in a handler only reverts a discarded call and cannot fail the suite.
    bool public sawFloorBreach;
    bool public sawUnhealthyBorrow;
    bool public sawSharePriceDecrease;
    /// @dev Set when a fee claim went through and left the position unhealthy (§7 post-condition).
    bool public sawUnhealthyClaim;
    /// @dev Set when a liquidity removal went through and left the debt over the borrow limit, or what
    ///      stayed under the pool's minimum (§7 post-condition, §4.1 v0.59).
    bool public sawUnsoundRemoval;
    address internal constant FEE_RECIPIENT = address(0xFEE5);

    constructor(
        FarmentaMarket market_,
        MarketLens lens_,
        uint256 tokenId_,
        uint256 idleTokenId_,
        address idleHolder_,
        address borrower_,
        address lender_,
        address owner_
    ) {
        market = market_;
        lens = lens_;
        usdg = IERC20(market_.asset());
        tokenId = tokenId_;
        idleTokenId = idleTokenId_;
        idleHolder = idleHolder_;
        borrower = borrower_;
        lender = lender_;
        owner = owner_;
    }

    function borrow(
        uint256 amount
    ) external {
        uint256 maximum = lens.maxBorrow(tokenId);
        if (maximum < 10e6) return;
        amount = bound(amount, 10e6, maximum);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        if (lens.healthFactor(tokenId) < 1e18) sawUnhealthyBorrow = true;
    }

    /// @dev Only amounts the market must refuse. On the intact market every call reverts and is
    ///      discarded; kept apart from `borrow` so that action's successes are not diluted.
    function borrowPastTheLimit(
        uint256 amount
    ) external {
        uint256 maximum = lens.maxBorrow(tokenId);
        amount = bound(amount, Math.max(maximum + 1, 10e6), Math.max(maximum, 10e6) * 2);
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        if (lens.healthFactor(tokenId) < 1e18) sawUnhealthyBorrow = true;
    }

    function repay(
        uint256 amount
    ) external {
        uint256 debt = market.debtOf(tokenId);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        deal(address(usdg), borrower, amount);
        vm.startPrank(borrower);
        usdg.approve(address(market), amount);
        market.repay(tokenId, amount);
        vm.stopPrank();
    }

    function deposit(
        uint256 amount
    ) external {
        amount = bound(amount, 1, 100e6);
        deal(address(usdg), lender, amount);
        vm.startPrank(lender);
        usdg.approve(address(market), amount);
        market.deposit(amount, lender);
        vm.stopPrank();
    }

    function withdraw(
        uint256 amount
    ) external {
        uint256 maximum = market.maxWithdraw(lender);
        if (maximum == 0) return;
        amount = bound(amount, 1, maximum);
        vm.prank(lender);
        market.withdraw(amount, lender, lender);
    }

    /// @dev Reaches the market only in runs where interest has taken reserves past the floor, which
    ///      needs `passTime`'s long steps: 3 to 5 successful withdrawals per campaign (FAR-61), none
    ///      when steps were capped at 30 days. Amounts come from the lens, so this action cannot ask
    ///      for more than the floor leaves; `withdrawReservesPastTheFloor` does.
    function withdrawReserves(
        uint256 amount
    ) external {
        uint256 maximum = lens.withdrawableReserves();
        if (maximum == 0) return;
        amount = bound(amount, 1, maximum);
        vm.prank(owner);
        market.withdrawReserves(amount, owner);
        if (market.reserves() < lens.reserveFloor()) sawFloorBreach = true;
    }

    /// @dev Only amounts the market must refuse: past what the floor leaves, up to every reserve the
    ///      cash can pay. `withdrawReserves` alone cannot reach them, since its bound comes from the
    ///      lens, which computes the floor apart from the market's gate: a gate that dropped the floor
    ///      would never be asked for more. Accrues first so the lens and the gate see the same reserves.
    function withdrawReservesPastTheFloor(
        uint256 amount
    ) external {
        market.accrue();
        uint256 minimum = lens.withdrawableReserves() + 1;
        uint256 maximum = Math.min(market.reserves(), usdg.balanceOf(address(market)));
        if (maximum < minimum) return;
        amount = bound(amount, minimum, maximum);
        vm.prank(owner);
        market.withdrawReserves(amount, owner);
        if (market.reserves() < lens.reserveFloor()) sawFloorBreach = true;
    }

    /// @dev The fork holds no swaps between calls, so after the first claim the fees are zero. What
    ///      this exercises is the post-condition on every claim the fuzzer reaches, at whatever debt and
    ///      index the other actions left.
    ///
    ///      That also means the market never has a claim to refuse here: with nothing to release, a
    ///      claim cannot lower the health factor, and no action brings the position under 1 first.
    ///      Removing `requireHealthy` from `collectFees` leaves
    ///      `invariant_aClaimNeverLeavesThePositionUnhealthy` green (FAR-59). `MarketCollectFees.t.sol`
    ///      guards that check; this ghost needs either fees that lower the health factor (a swap
    ///      between claims) or a claim on a position already under 1 before it can fire (FAR-62).
    function collectFees() external {
        vm.prank(borrower);
        market.collectFees(tokenId, FEE_RECIPIENT);
        if (lens.healthFactor(tokenId) < 1e18) sawUnhealthyClaim = true;
    }

    /// @dev Any amount up to everything the position holds. The market refuses the removals that go
    ///      too far, and the handler discards those reverts; what is recorded is one it let through
    ///      that it should not have: a debt over the borrow limit of what stays (§4.1 v0.59), or a
    ///      remainder under the pool's minimum after its removal haircut (§6.1). Both bounds are read
    ///      from the policy, not written here. USDG is priced at exactly one dollar in this suite, so
    ///      a debt in USD 1e18 is the USDG amount times 1e12.
    function decreaseLiquidity(
        uint128 amount
    ) external {
        _remove(tokenId, borrower, amount, 1);
    }

    /// @dev The same removal on the position that owes nothing, where only the minimum can refuse it.
    ///      At least half of what is held each time: the fuzzer's amounts are otherwise small against
    ///      the position, and a run never brings it near the minimum.
    function decreaseIdleLiquidity(
        uint128 amount
    ) external {
        _remove(idleTokenId, idleHolder, amount, 2);
    }

    function _remove(
        uint256 id,
        address holder,
        uint128 amount,
        uint128 leastShare
    ) private {
        uint128 held = market.positionManager().getPositionLiquidity(id);
        amount = uint128(bound(amount, leastShare == 1 ? 1 : held / leastShare, held));
        vm.prank(holder);
        market.decreaseLiquidity(id, amount, 0, 0, FEE_RECIPIENT);

        ICollateralPolicy.Terms memory terms = market.policy().termsOf(market.loanOf(id).poolKeyId);
        uint256 limitUsd = lens.positionValue(id) * Math.min(terms.maxLtvBps, terms.ltBps) / 10_000;
        uint256 recoverableUsd = market.valuer().value(id).principalUsd * (10_000 - terms.removeHaircutBps) / 10_000;
        if (market.debtOf(id) * 1e12 > limitUsd || recoverableUsd < terms.minPositionUsd) {
            sawUnsoundRemoval = true;
        }
    }

    /// @dev Up to a year per call. Reserves grow only by 15% of the interest, and the blue-chip floor is
    ///      1% of `totalAssets`: at the setup's 43% utilization that is years of accrual. With steps of at
    ///      most 30 days no run took reserves past it (FAR-61). A year lets a run cross it, most of all
    ///      after `withdraw` has drained the cash and utilization sits at the top of the curve.
    function passTime(
        uint40 elapsed
    ) external {
        uint256 oneShare = 10 ** market.decimals();
        uint256 assetsBefore = market.convertToAssets(oneShare);
        vm.warp(block.timestamp + bound(uint256(elapsed), 1 hours, 365 days));
        market.accrue();
        if (market.convertToAssets(oneShare) < assetsBefore) sawSharePriceDecrease = true;
    }
}

/// @notice Solvency assertions over a real fork position after a user borrow action.
/// @dev This suite intentionally lives in the fork lane: it values a real Uniswap position.
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 32
contract MarketSolvencyInvariantTest is MarketForkTest {
    uint256 internal tokenId;
    MarketHandler internal handler;
    address internal borrower;
    address internal lender = address(0x1E4DE2);

    function setUp() public override {
        super.setUp();
        tokenId = Fixtures.POS_ETH_USDG_DYN_IN_RANGE;
        _listPoolOf(tokenId, 50e18);
        borrower = nft.ownerOf(tokenId);
        vm.startPrank(borrower);
        nft.approve(address(market), tokenId);
        market.depositCollateral(tokenId);
        vm.stopPrank();

        deal(market.asset(), lender, 300e6);
        vm.startPrank(lender);
        IERC20(market.asset()).approve(address(market), type(uint256).max);
        market.deposit(300e6, lender);
        vm.stopPrank();

        uint256 amount = lens.maxBorrow(tokenId) / 2;
        vm.prank(borrower);
        market.borrow(tokenId, amount, borrower);
        uint256 idleTokenId = Fixtures.POS_WETH_USDG_WIDE_IN_RANGE;
        _listPoolOf(idleTokenId, 50e18);
        address idleHolder = nft.ownerOf(idleTokenId);
        vm.startPrank(idleHolder);
        nft.approve(address(market), idleTokenId);
        market.depositCollateral(idleTokenId);
        vm.stopPrank();

        handler = new MarketHandler(market, lens, tokenId, idleTokenId, idleHolder, borrower, lender, market.owner());
        targetContract(address(handler));
    }

    function invariant_totalBorrowsMatchesBorrowSharesAndIndex() public view {
        assertEq(market.totalBorrows(), market.totalBorrowShares() * market.borrowIndex() / 1e18);
    }

    /// @dev Only bites once reserves pass the floor and `withdraw` drains the cash under what they leave.
    ///      A lens without its cash cap turns this red; before FAR-61 no run reached that state.
    function invariant_withdrawableNeverExceedsCash() public view {
        assertLe(lens.withdrawableReserves(), IERC20(market.asset()).balanceOf(address(market)));
    }

    function invariant_borrowNeverLeavesAnUnhealthyPosition() public view {
        assertFalse(handler.sawUnhealthyBorrow(), "borrow accepted an unhealthy position");
    }

    function invariant_accrualNeverReducesTheVaultSharePrice() public view {
        assertFalse(handler.sawSharePriceDecrease(), "accrual reduced the vault share price");
    }

    function invariant_aClaimNeverLeavesThePositionUnhealthy() public view {
        assertFalse(handler.sawUnhealthyClaim(), "a fee claim left the position unhealthy");
    }

    function invariant_aRemovalNeverLeavesThePositionUnsound() public view {
        assertFalse(
            handler.sawUnsoundRemoval(),
            "a liquidity removal left the debt over the borrow limit or the position under the minimum"
        );
    }

    function invariant_withdrawalNeverBreachesTheFloor() public view {
        assertFalse(handler.sawFloorBreach(), "a withdrawal left reserves below the floor");
    }
}
