// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC721Permit_v4} from "@uniswap/v4-periphery/src/interfaces/IERC721Permit_v4.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "./interfaces/IPositionValuer.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {TierPresets} from "./libraries/TierPresets.sol";

/// @title FarmentaMarket
/// @notice Custodies Uniswap v4 LP position NFTs and lends USDG against them
///         (ARCHITECTURE §4.1). One implementation, two proxies: Blue-chip and Meme.
/// @dev **This contract currently implements the custody half only.** Collateral can be
///      deposited and withdrawn; the debt ledger, interest accrual, borrowing, repayment and
///      liquidation land in Phase 1 (§16). The ERC-4626 side is inherited and functional, but
///      earns nothing yet: with no borrows, `totalAssets` is simply the USDG this contract
///      holds. §7 overrides it once `totalBorrows` and `reserves` exist.
///
///      **Two more overrides land with that ledger, and are owed now so they are not
///      discovered later.** §4.1 limits a lender's withdrawal to the cash actually on hand.
///      The inherited `maxWithdraw` and `maxRedeem` measure against `totalAssets`, which is
///      harmless while nothing is borrowed — cash *is* `totalAssets` — but once borrows exist
///      they would advertise more than the vault can pay, and `withdraw` would fail inside the
///      token transfer instead of reverting as `ERC4626ExceededMaxWithdraw`. Both must be
///      bounded by cash in the same change that introduces `totalBorrows`.
///
///      **ETH that arrives has no way out.** `receive()` accepts it because the payout
///      functions will need it (see the note there), but nothing in this version sends it
///      anywhere, and §4.1's owner-function list has no ETH rescue. Nothing today can make
///      ETH arrive legitimately, so this is a question for the §8 work that first produces a
///      payout rather than a defect here; it is recorded as spec open item §15 no. 12 so the
///      answer is decided with those functions and not after them.
///
///      **Upgrade power.** `_authorizeUpgrade` is `onlyOwner` with no timelock (§4.1, decided
///      4 Sep 2026). This contract custodies collateral NFTs and holds USDG deposits, so
///      whoever holds the owner key can replace its entire logic, including taking
///      everything, in one transaction and without warning. That is the largest risk in the
///      protocol (§15 no. 9) and is accepted only while there is no real TVL.
///
///      **Storage discipline.** State lives under an ERC-7201 namespace, so adding variables
///      in a later version cannot shift a slot already in use. Inherited OpenZeppelin
///      upgradeable contracts namespace their own storage the same way, which is why the
///      ERC-4626 parent can be added or extended later without disturbing this one.
contract FarmentaMarket is
    ERC4626Upgradeable,
    ERC721Holder,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice A position held as collateral, and what is owed against it.
    /// @param owner The address that deposited it, and the only one who may take it back.
    /// @param debtShares Share of `totalBorrows` owed. Always zero until the debt ledger
    ///        lands in Phase 1; `withdrawCollateral` already refuses a non-zero value, so
    ///        that gate does not have to be retrofitted later.
    /// @dev §4.1 also lists `poolKeyId` and `tier` on this struct. Both exist to serve the
    ///      per-pool debt cap and the market-tier check at borrow time, and neither is
    ///      readable state today: the pool is recoverable from `getPoolAndPositionInfo`, and
    ///      a market serves exactly one tier. They arrive with the ledger that needs them.
    struct Loan {
        address owner;
        uint256 debtShares;
        PoolId poolKeyId;
        ICollateralPolicy.Tier tier;
    }

    /// @custom:storage-location erc7201:farmenta.storage.Market
    struct MarketStorage {
        /// @dev Which tier this proxy accepts. Storage rather than an immutable because one
        ///      implementation backs both markets, and they differ only here.
        ICollateralPolicy.Tier tier;
        mapping(uint256 tokenId => Loan) loans;
        mapping(PoolId poolId => uint256) poolDebtShares;
        uint256 totalBorrowShares;
        uint256 totalBorrows;
        uint256 borrowIndex;
        uint256 lastAccrual;
        uint256 reserves;
        uint16 reserveFactorBps;
        uint16 reserveFloorBps;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("farmenta.storage.Market")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKET_STORAGE_LOCATION =
        0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;

    /// @notice Decimal offset on the vault's shares, against inflation attacks (§7).
    uint8 private constant DECIMALS_OFFSET = 3;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    /// @notice The Uniswap position NFT this market custodies.
    /// @dev Immutable in the implementation and changed by upgrading, like every other
    ///      dependency here (§4.1): each extra proxy would double the storage-collision
    ///      surface without adding a capability.
    IPositionManager public immutable positionManager;

    /// @notice Decides which pools may back a loan, and on what terms (§4.5, §6).
    ICollateralPolicy public immutable policy;

    /// @notice Values a position at oracle prices (§4.2, §5.1).
    IPositionValuer public immutable valuer;

    /// @notice Price oracle reserved for the FAR-20 borrow price gate.
    IPriceOracle public immutable oracle;

    /// @notice Immutable rate curve for this market's tier.
    IInterestRateModel public immutable interestRateModel;

    /// @notice A position was taken into custody as collateral.
    event CollateralDeposited(uint256 indexed tokenId, address indexed owner);

    /// @notice A position was released back to the depositor.
    event CollateralWithdrawn(uint256 indexed tokenId, address indexed owner);

    /// @notice A position that arrived here unrecorded was swept out by the owner.
    event UnaccountedTokenRescued(uint256 indexed tokenId, address indexed to);
    event Borrow(uint256 indexed tokenId, uint256 amount);
    event Repay(uint256 indexed tokenId, uint256 amount);
    event ReservesUpdated(uint256 reserves);

    error ZeroAddress();
    error TierNotSet();
    error NotThePositionManager(address caller);
    error PositionAlreadyHeld(uint256 tokenId);
    error PositionIsEmpty(uint256 tokenId);
    error PositionBelowMinimum(uint256 principalUsd, uint256 minimumUsd);
    error PermitRejected(uint256 tokenId);
    error NotTheDepositor(uint256 tokenId, address depositor);
    error OutstandingDebt(uint256 tokenId, uint256 debtShares);
    error InvalidRecipient(address to);
    error PositionIsCollateral(uint256 tokenId);
    error BorrowerNotAuthorized(uint256 tokenId, address borrower);
    error InvalidBorrowRecipient(address to);
    error BorrowExceedsMaxLtv(uint256 requestedDebt, uint256 maximumDebt);
    error BorrowBelowMinimum(uint256 debt);
    error ZeroBorrowAmount();
    error PoolDebtCapExceeded(PoolId poolId, uint256 requestedDebt, uint256 debtCap);
    error MarketDebtCapExceeded(uint256 requestedDebt, uint256 debtCap);
    error PoolNotOpenForBorrowing(PoolId poolId);

    /// @param positionManager_ Uniswap v4 PositionManager, the only NFT this market takes.
    /// @param policy_ Collateral policy the market defers listing decisions to.
    /// @param valuer_ Position valuer the market prices collateral with.
    /// @dev Constructor only sets immutables and locks the implementation. All proxy state is
    ///      established in `initialize`.
    constructor(
        IPositionManager positionManager_,
        ICollateralPolicy policy_,
        IPositionValuer valuer_,
        IPriceOracle oracle_,
        IInterestRateModel interestRateModel_
    ) {
        if (
            address(positionManager_) == address(0) || address(policy_) == address(0) || address(valuer_) == address(0)
                || address(oracle_) == address(0) || address(interestRateModel_) == address(0)
        ) {
            revert ZeroAddress();
        }

        positionManager = positionManager_;
        policy = policy_;
        valuer = valuer_;
        oracle = oracle_;
        interestRateModel = interestRateModel_;

        _disableInitializers();
    }

    /// @notice Initialises one proxy.
    /// @param asset_ The borrow asset and vault asset. USDG in the MVP (§1 #4).
    /// @param name_ ERC-20 name of the share token, e.g. "Farmenta USDG Blue-chip".
    /// @param symbol_ ERC-20 symbol, e.g. "fUSDG-BC" (§3).
    /// @param tier_ Which collateral tier this proxy accepts.
    /// @param owner_ Holder of every privileged function, including upgrades.
    /// @dev `Tier.NONE` is rejected rather than stored: it is the unconfigured value, and a
    ///      market that accepted it would compare equal to every unlisted pool's tier.
    function initialize(
        IERC20 asset_,
        string calldata name_,
        string calldata symbol_,
        ICollateralPolicy.Tier tier_,
        address owner_
    ) external initializer {
        if (tier_ == ICollateralPolicy.Tier.NONE) revert TierNotSet();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Pausable_init();
        __Ownable_init(owner_);
        __Ownable2Step_init();

        MarketStorage storage $ = _marketStorage();
        $.tier = tier_;
        $.borrowIndex = WAD;
        $.lastAccrual = block.timestamp;
        ($.reserveFactorBps, $.reserveFloorBps) = tier_ == ICollateralPolicy.Tier.BLUE_CHIP ? (1500, 100) : (2500, 250);
    }

    /* -------------------------------- collateral ------------------------------ */

    /// @notice Takes a Uniswap v4 position into custody as collateral.
    /// @param tokenId The position NFT. Must be approved to this market first, or use
    ///        `depositCollateralWithPermit` to approve and deposit in one transaction.
    /// @dev Custody, not a lien: the market becomes the NFT's owner. That is the point rather
    ///      than an implementation detail. `PositionManager` gates `DECREASE_LIQUIDITY` and
    ///      `BURN_POSITION` behind `onlyIfApproved(msgSender())`, so owning the NFT is what
    ///      lets this contract pull liquidity during liquidation. The subscriber mechanism
    ///      cannot substitute: an owner can always unsubscribe, and a transfer unsubscribes
    ///      automatically (§10).
    ///
    ///      Pulled with `transferFrom` rather than `safeTransferFrom` deliberately. This
    ///      contract is the recipient and is known to accept the token, and the plain
    ///      transfer fires no `onERC721Received`, which keeps this path from re-entering the
    ///      one below.
    function depositCollateral(
        uint256 tokenId
    ) external whenNotPaused nonReentrant {
        IERC721(address(positionManager)).transferFrom(msg.sender, address(this), tokenId);
        _acceptCollateral(msg.sender, tokenId);
    }

    /// @notice Approves and deposits in one transaction, using a signature from the owner.
    /// @param tokenId The position NFT.
    /// @param deadline After which the signature is no longer valid.
    /// @param nonce Any nonce the owner has not spent. Uniswap's nonces are unordered, so
    ///        this need not follow on from a previous one.
    /// @param signature The owner's EIP-712 `Permit`, 65 bytes or the compact 64-byte form.
    /// @dev **The signature is not an ERC-721 standard one.** ERC-721 has no permit; this is
    ///      Uniswap's own `ERC721Permit_v4`, and its EIP-712 domain omits `version`, carrying
    ///      only name, chainId and verifyingContract. A signer that assembles the usual
    ///      four-field domain produces a signature that always fails. Note also that the
    ///      arguments here follow Uniswap's function order, deadline then nonce, while the
    ///      signed struct hashes them the other way round.
    ///
    ///      The position is credited to its owner rather than to `msg.sender`. The owner is
    ///      who signed, the signature names this market as the only possible spender, and the
    ///      collateral is withdrawable only by them, so letting someone else pay the gas costs
    ///      nobody anything.
    ///
    ///      A signed permit is public once broadcast and anyone may submit it, so it can be
    ///      spent between this transaction being signed and being mined. Losing that race is
    ///      not a failure as long as it left this market approved, which is the only thing the
    ///      call was for.
    ///
    ///      The fallback checks the per-token approval and nothing else. That is exactly the
    ///      state the lost race leaves behind — the spender is part of the signed struct, so
    ///      whoever spends the permit grants `getApproved(tokenId) == address(this)` and no
    ///      other approval. Accepting a blanket `isApprovedForAll` here would be wider than
    ///      the case being defended: an owner who had ever made this market an operator could
    ///      have any of their positions pushed in by a stranger holding a garbage signature.
    function depositCollateralWithPermit(
        uint256 tokenId,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        IERC721 nft = IERC721(address(positionManager));
        address depositor = nft.ownerOf(tokenId);

        try IERC721Permit_v4(address(positionManager)).permit(address(this), tokenId, deadline, nonce, signature) {}
        catch {
            if (nft.getApproved(tokenId) != address(this)) revert PermitRejected(tokenId);
        }

        nft.transferFrom(depositor, address(this), tokenId);
        _acceptCollateral(depositor, tokenId);
    }

    /// @notice Accepts a position pushed here directly with `safeTransferFrom`.
    /// @dev The second intake path, and it runs exactly the same checks as the first. A
    ///      position that fails them makes the transfer revert, so the sender keeps their NFT
    ///      rather than stranding it here.
    ///
    ///      `msg.sender` must be the Uniswap `PositionManager`. Without that check any ERC-721
    ///      would do, and a worthless token of the depositor's own making would be recorded as
    ///      collateral — the policy and valuer both key off `tokenId` alone and would be
    ///      reading a different contract's state.
    ///
    ///      Note what this does *not* catch. `PositionManager` mints with solmate's `_mint`,
    ///      which fires no callback, so a position minted straight to this address never
    ///      reaches here and is never recorded. `rescueUnaccountedToken` exists for exactly
    ///      that case (§4.1).
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes memory
    ) public override whenNotPaused nonReentrant returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotThePositionManager(msg.sender);
        _acceptCollateral(from, tokenId);
        return this.onERC721Received.selector;
    }

    /// @notice Returns a position to the depositor once nothing is owed against it.
    /// @param tokenId The position to release.
    /// @param to Where to send it. The depositor's choice, so they can move it straight on.
    /// @dev **Deliberately not pausable.** Everything that takes on new risk stops when the
    ///      market is paused; this does not. A position with no debt against it belongs
    ///      entirely to its depositor, so refusing to hand it back protects nobody and turns
    ///      an operational lever into a way to strand other people's assets. §6.5 makes the
    ///      same call for frozen pools, and for the same reason.
    ///
    ///      Sent with `safeTransferFrom`: the recipient is whatever address the depositor
    ///      names, and a contract that cannot hold ERC-721s should make the call revert rather
    ///      than swallow the position. Re-entry through that callback is closed off by
    ///      clearing the record first and by the guard on this function.
    function withdrawCollateral(
        uint256 tokenId,
        address to
    ) external nonReentrant {
        accrue();
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);

        MarketStorage storage $ = _marketStorage();
        Loan memory loan = $.loans[tokenId];

        if (loan.owner != msg.sender) revert NotTheDepositor(tokenId, loan.owner);
        // Vacuous until Phase 1 writes the ledger, and deliberately here anyway: the gate that
        // stops a borrower walking away with their collateral should not be one that has to be
        // remembered later.
        if (loan.debtShares != 0) revert OutstandingDebt(tokenId, loan.debtShares);

        delete $.loans[tokenId];
        emit CollateralWithdrawn(tokenId, msg.sender);

        IERC721(address(positionManager)).safeTransferFrom(address(this), to, tokenId);
    }

    /// @notice Accepts native ETH (§4.1).
    /// @dev Pools whose `currency0` is `address(0)` pay out in ETH, so `TAKE_PAIR` will send it
    ///      here when collecting fees, decreasing liquidity or liquidating. None of those exist
    ///      yet and nothing in this version can make ETH arrive, but the alternative is a
    ///      market that rejects the first payout it is ever handed.
    ///
    ///      ETH that turns up before then has no accounting and no way out. That is the same
    ///      trapped-asset hole `rescueUnaccountedToken` closes, one asset class over, and it
    ///      is left open deliberately: §4.1 gives the owner no ETH rescue, and adding one
    ///      before there is any legitimate ETH flow would decide by accident how ETH payouts
    ///      are accounted for. Open item §15 no. 12, to be answered by the §8 work.
    receive() external payable {}

    /* ---------------------------------- views --------------------------------- */

    /// @notice The collateral tier this market accepts.
    function tier() external view returns (ICollateralPolicy.Tier) {
        return _marketStorage().tier;
    }

    /// @notice The loan recorded against a position, or a zeroed record if there is none.
    function loanOf(
        uint256 tokenId
    ) external view returns (Loan memory) {
        return _marketStorage().loans[tokenId];
    }

    /// @notice Accrues index-based interest since the last state-changing operation.
    function accrue() public {
        MarketStorage storage $ = _marketStorage();
        uint256 elapsed = block.timestamp - $.lastAccrual;
        if (elapsed == 0) return;

        $.lastAccrual = block.timestamp;
        if ($.totalBorrowShares == 0) return;

        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 utilization = $.totalBorrows * WAD / (cash + $.totalBorrows);
        uint256 rate = interestRateModel.ratePerSecond(utilization);
        uint256 newIndex = $.borrowIndex + $.borrowIndex * rate * elapsed / WAD;
        uint256 newTotalBorrows = $.totalBorrowShares.mulDiv(newIndex, WAD);
        uint256 interest = newTotalBorrows - $.totalBorrows;

        $.borrowIndex = newIndex;
        $.totalBorrows = newTotalBorrows;
        $.reserves += interest * $.reserveFactorBps / BPS;
        emit ReservesUpdated($.reserves);
    }

    /// @notice Borrows USDG against a deposited position, subject to LTV and debt caps.
    function borrow(
        uint256 tokenId,
        uint256 amount,
        address to
    ) external whenNotPaused nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidBorrowRecipient(to);
        if (amount == 0) revert ZeroBorrowAmount();
        accrue();

        MarketStorage storage $ = _marketStorage();
        Loan storage loan = $.loans[tokenId];
        if (loan.owner != msg.sender) revert BorrowerNotAuthorized(tokenId, msg.sender);
        if (!policy.acceptsNewPositions(loan.poolKeyId)) revert PoolNotOpenForBorrowing(loan.poolKeyId);

        // FAR-20 installs fresh-price, USDG-bound, and spot-deviation checks at this boundary.
        ICollateralPolicy.Terms memory terms = policy.termsOf(loan.poolKeyId);
        uint256 requestedDebt = debtOf(tokenId) + amount;
        uint256 requestedDebtUsd = _debtUsd(requestedDebt);
        uint256 maximumDebtUsd = _borrowValue(tokenId) * terms.maxLtvBps / BPS;
        if (requestedDebtUsd > maximumDebtUsd) revert BorrowExceedsMaxLtv(requestedDebtUsd, maximumDebtUsd);
        if (requestedDebtUsd < 10e18) revert BorrowBelowMinimum(requestedDebtUsd);
        uint256 requestedPoolDebt = _poolDebt(loan.poolKeyId) + amount;
        if (requestedPoolDebt > terms.debtCapUsdg) {
            revert PoolDebtCapExceeded(loan.poolKeyId, requestedPoolDebt, terms.debtCapUsdg);
        }

        uint256 marketDebtCap = TierPresets.forTier($.tier).maxDebtCapUsdg;
        if ($.totalBorrows + amount > marketDebtCap) {
            revert MarketDebtCapExceeded($.totalBorrows + amount, marketDebtCap);
        }

        uint256 shares = amount.mulDiv(WAD, $.borrowIndex, Math.Rounding.Ceil);
        loan.debtShares += shares;
        $.totalBorrowShares += shares;
        $.poolDebtShares[loan.poolKeyId] += shares;
        $.totalBorrows = $.totalBorrowShares.mulDiv($.borrowIndex, WAD);
        IERC20(asset()).safeTransfer(to, amount);
        emit Borrow(tokenId, amount);
    }

    /// @notice Repays debt. Pass `type(uint256).max` to repay the complete outstanding debt.
    function repay(
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant returns (uint256 repaid) {
        accrue();
        MarketStorage storage $ = _marketStorage();
        Loan storage loan = $.loans[tokenId];
        uint256 debt = loan.debtShares.mulDiv($.borrowIndex, WAD);
        if (amount == type(uint256).max || amount > debt) amount = debt;
        if (amount == 0) return 0;

        uint256 shares = amount == debt ? loan.debtShares : amount.mulDiv(WAD, $.borrowIndex);
        repaid = shares.mulDiv($.borrowIndex, WAD);
        loan.debtShares -= shares;
        $.totalBorrowShares -= shares;
        $.poolDebtShares[loan.poolKeyId] -= shares;
        $.totalBorrows = $.totalBorrowShares.mulDiv($.borrowIndex, WAD);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), repaid);
        emit Repay(tokenId, repaid);
    }

    function debtOf(
        uint256 tokenId
    ) public view returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        return $.loans[tokenId].debtShares.mulDiv($.borrowIndex, WAD);
    }

    function positionValue(
        uint256 tokenId
    ) public view returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        Loan storage loan = $.loans[tokenId];
        if (loan.owner == address(0)) return 0;
        ICollateralPolicy.Terms memory terms = policy.termsOf(loan.poolKeyId);
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        return valuation.principalUsd * (BPS - terms.removeHaircutBps) / BPS;
    }

    function maxBorrow(
        uint256 tokenId
    ) public view returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        Loan storage loan = $.loans[tokenId];
        if (loan.owner == address(0)) return 0;
        uint256 maximumDebtUsd = _borrowValue(tokenId) * policy.termsOf(loan.poolKeyId).maxLtvBps / BPS;
        uint256 debtUsd = _debtUsd(debtOf(tokenId));
        if (maximumDebtUsd <= debtUsd) return 0;
        return _usdToDebt(maximumDebtUsd - debtUsd);
    }

    function healthFactor(
        uint256 tokenId
    ) external view returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        Loan storage loan = $.loans[tokenId];
        uint256 debtUsd = _debtUsd(debtOf(tokenId));
        if (debtUsd == 0) return type(uint256).max;
        return positionValue(tokenId) * policy.termsOf(loan.poolKeyId).ltBps * WAD / (debtUsd * BPS);
    }

    function totalBorrows() external view returns (uint256) {
        return _marketStorage().totalBorrows;
    }

    function borrowIndex() external view returns (uint256) {
        return _marketStorage().borrowIndex;
    }

    function reserves() external view returns (uint256) {
        return _marketStorage().reserves;
    }

    function poolDebt(
        PoolId poolId
    ) external view returns (uint256) {
        return _poolDebt(poolId);
    }

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        return IERC20(asset()).balanceOf(address(this)) + $.totalBorrows - $.reserves;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxWithdraw(
        address owner
    ) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), IERC20(asset()).balanceOf(address(this)));
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(
        address owner
    ) public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 cashLimitedShares = convertToShares(cash);
        return Math.min(super.maxRedeem(owner), cashLimitedShares);
    }

    /* ---------------------------------- owner --------------------------------- */

    /// @notice Halts the operations that take on new risk.
    /// @dev The MVP mitigation for sequencer downtime (§5.2): Robinhood Chain publishes no
    ///      Chainlink L2 Sequencer Uptime Feed, so pausing is the only lever available.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recovers a position that reached this contract without being recorded.
    /// @param tokenId The unaccounted position.
    /// @param to Where to send it.
    /// @dev Two ways a position lands here unrecorded, and neither runs the intake callback.
    ///      `PositionManager` mints with solmate's `_mint`, which fires no callback at all, so
    ///      anyone can mint a position whose owner is this contract. And a plain `transferFrom`
    ///      is not a `safeTransferFrom`, so it too arrives silently. Without this the position
    ///      would sit here forever, belonging to nobody the market can name (§4.1).
    ///
    ///      The guard is the whole point: this refuses any position with a loan record against
    ///      it, so it can never be turned on collateral somebody actually deposited. It closes
    ///      a trapped-asset hole without opening a theft one.
    function rescueUnaccountedToken(
        uint256 tokenId,
        address to
    ) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        if (_marketStorage().loans[tokenId].owner != address(0)) revert PositionIsCollateral(tokenId);

        emit UnaccountedTokenRescued(tokenId, to);
        IERC721(address(positionManager)).safeTransferFrom(address(this), to, tokenId);
    }

    /* -------------------------------- internals ------------------------------- */

    /// @dev Runs every §6.1 admission rule and records the loan. Called once the market
    ///      already owns the NFT, which both intake paths guarantee.
    ///
    ///      The pool-level rules live in `CollateralPolicy.checkPool`: listed, not frozen,
    ///      right tier, both tokens enabled, quoted in USDG, hook permitted. The two rules
    ///      that need the position itself are enforced here, because §4.5 keeps the policy
    ///      free of dependencies and the market has already paid for the valuation.
    ///
    ///      The minimum is measured on **principal alone**, not principal plus fees. A
    ///      depositor can collect their fees the moment the position is in, so counting them
    ///      toward the floor would admit positions that fall under it one transaction later.
    ///      Fees are collateral (§1 #6); they are just not a reason to let dust in.
    function _acceptCollateral(
        address depositor,
        uint256 tokenId
    ) private {
        MarketStorage storage $ = _marketStorage();
        // Unreachable today, since a recorded position is one this contract already owns and
        // so cannot be handed to it again. Kept because it guards the single record that must
        // never be silently overwritten, and `mintAndDeposit` (§4.1, Phase 2) adds an intake
        // path that does not start from a transfer.
        if ($.loans[tokenId].owner != address(0)) revert PositionAlreadyHeld(tokenId);

        // No existence check: both intake paths reach here holding the NFT, and
        // `PositionManager` clears a position's info in the same call that burns its token.
        // Owning it therefore implies it exists. Were that ever untrue, the zeroed key names
        // a pool that cannot be listed anyway, since neither of its currencies is USDG.
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);

        ICollateralPolicy.Terms memory terms = policy.checkPool(key, $.tier);

        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        if (valuation.liquidity == 0) revert PositionIsEmpty(tokenId);

        // §6.3: a hook that skims on withdrawal has its cut recorded at listing and deducted
        // from the value. What backs a loan is what the protocol could actually pull out, not
        // what the position reads as on paper. The policy caps the haircut at 100%, so this
        // cannot underflow.
        uint256 recoverableUsd = valuation.principalUsd * (BPS - terms.removeHaircutBps) / BPS;
        if (recoverableUsd < terms.minPositionUsd) {
            revert PositionBelowMinimum(recoverableUsd, terms.minPositionUsd);
        }

        $.loans[tokenId] = Loan({owner: depositor, debtShares: 0, poolKeyId: key.toId(), tier: $.tier});
        emit CollateralDeposited(tokenId, depositor);
    }

    /// @dev Borrow capacity admits at most 10% of principal in unclaimed fees. Health factor
    ///      deliberately excludes fees: their owner may claim them at any time.
    function _borrowValue(
        uint256 tokenId
    ) private view returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        Loan storage loan = $.loans[tokenId];
        ICollateralPolicy.Terms memory terms = policy.termsOf(loan.poolKeyId);
        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        uint256 cappedFees = Math.min(valuation.feesUsd, valuation.principalUsd / 10);
        return (valuation.principalUsd + cappedFees) * (BPS - terms.removeHaircutBps) / BPS;
    }

    /// @dev Converts USDG-denominated debt to USD 1e18 using the configured oracle price.
    function _debtUsd(
        uint256 debt
    ) private view returns (uint256) {
        Currency assetCurrency = Currency.wrap(asset());
        return debt.mulDiv(oracle.price(assetCurrency), 10 ** oracle.decimals(assetCurrency));
    }

    /// @dev Floors a USD value to the amount of USDG that can be borrowed without exceeding it.
    function _usdToDebt(
        uint256 usdValue
    ) private view returns (uint256) {
        Currency assetCurrency = Currency.wrap(asset());
        return usdValue.mulDiv(10 ** oracle.decimals(assetCurrency), oracle.price(assetCurrency));
    }

    function _poolDebt(
        PoolId poolId
    ) private view returns (uint256) {
        MarketStorage storage $ = _marketStorage();
        return $.poolDebtShares[poolId].mulDiv($.borrowIndex, WAD);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Owner-only, no timelock. See the trust note on this contract.
    function _authorizeUpgrade(
        address
    ) internal override onlyOwner {}

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Both `deposit` and `mint` route through here, so pausing stops the vault taking
    ///      new money while `withdraw` and `redeem` stay open. The same asymmetry as the
    ///      collateral side: what takes on risk stops, what hands assets back does not. §5.2
    ///      makes pausing the only sequencer-downtime lever this chain offers, and continuing
    ///      to accept deposits during one would be the wrong half to leave running.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev A lender action changes cash, so it must settle the previous interval first.
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        accrue();
        return super.deposit(assets, receiver);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {
        accrue();
        return super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override returns (uint256) {
        accrue();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {
        accrue();
        return super.redeem(shares, receiver, owner);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _marketStorage() private pure returns (MarketStorage storage $) {
        assembly {
            $.slot := MARKET_STORAGE_LOCATION
        }
    }
}
