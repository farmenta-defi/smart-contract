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
import {ISignatureTransfer} from "permit2/src/interfaces/ISignatureTransfer.sol";

import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {IPositionValuer} from "./interfaces/IPositionValuer.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {DebtMath} from "./libraries/DebtMath.sol";
import {MarketDebt} from "./libraries/MarketDebt.sol";
import {MarketLedger} from "./libraries/MarketLedger.sol";
import {MarketLiquidation} from "./libraries/MarketLiquidation.sol";
import {MarketLiquidity} from "./libraries/MarketLiquidity.sol";
import {MarketMint} from "./libraries/MarketMint.sol";

/// @title FarmentaMarket
/// @notice Custodies Uniswap v4 LP position NFTs and lends USDG against them
///         (ARCHITECTURE §4.1). One implementation, two proxies: Blue-chip and Meme.
/// @dev **The lending side is whole as of §8.** Collateral goes in and comes back out, the
///      index-based ledger of §7 accrues against it, and an underwater position can now be
///      liquidated — which is what makes a lent dollar a dollar with a way home. A depositor
///      can also claim a held position's fees (`collectFees`, FAR-7), add liquidity to it
///      (`increaseLiquidity`, FAR-9) and remove part of it (`decreaseLiquidity`, FAR-8), which
///      completes §4.1's borrower surface.
///
///      **Logic lives in linked libraries; this contract keeps the wrappers** (§4.1 v0.33).
///      Borrow and repay run from `MarketDebt`, collateral intake from `MarketMint`, §8's seizure
///      from `MarketLiquidation`, fee claims and liquidity removals from `MarketLiquidity`, each by
///      `delegatecall`:
///      the market's storage, the
///      market's address, the caller's `msg.sender`, code at its own address. Risk views are
///      read from `MarketLens`, one per proxy. That is what keeps the implementation under
///      EIP-170 with the work still owed to come (spec §15 no. 17, FAR-32).
///
///      **ETH arrives and leaves through liquidation, and stray ETH has a way out.** A
///      native-ETH pool pays its seizure out as ETH, so `receive()` is on the path rather than
///      ahead of it. Nothing legitimate stays: liquidation forwards both legs in the same call,
///      the change of `mintAndDeposit` and `increaseLiquidity` leaves through `SWEEP` straight
///      from PositionManager, and the ETH of a fee claim or a liquidity removal goes from
///      PoolManager to its recipient without touching the market. So
///      ETH found here between transactions belongs to no one the market can name, and
///      `rescueUnaccountedEth` sweeps it — spec open item §15 no. 12, decided with §8 as that
///      item asked. Nor can a borrower use ETH to block its own liquidation: its share goes
///      out as WETH when it refuses ETH (see `MarketLiquidation`).
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

    /// @notice The position `mintAndDeposit` creates (§4.1).
    /// @param poolKey Pool to mint into. It passes the same §6.1 admission as any deposit.
    /// @param tickLower Lower tick of the range, on the pool's spacing.
    /// @param tickUpper Upper tick of the range, on the pool's spacing.
    /// @param liquidity Liquidity to mint.
    /// @param amount0Max The most currency0 the mint may cost. For a native-ETH pool this is
    ///        also exactly the `msg.value` to send.
    /// @param amount1Max The most currency1 the mint may cost.
    /// @param hookData Passed through to the pool's hook.
    struct MintParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        bytes hookData;
    }

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

    /// @notice Price oracle: the §5.2 borrow gates read it, and §8 reads its liquidation surface.
    IPriceOracle public immutable oracle;

    /// @notice Immutable rate curve for this market's tier.
    IInterestRateModel public immutable interestRateModel;

    /// @notice A position was taken into custody as collateral.
    event CollateralDeposited(uint256 indexed tokenId, address indexed owner);

    /// @notice A position was released back to the depositor.
    event CollateralWithdrawn(uint256 indexed tokenId, address indexed owner);

    /// @notice A position that arrived here unrecorded was swept out by the owner.
    event UnaccountedTokenRescued(uint256 indexed tokenId, address indexed to);

    /// @notice ETH that belonged to no payout was swept out by the owner (§15 no. 12).
    event UnaccountedEthRescued(uint256 amount, address indexed to);
    /// @notice Liquidity was added to (positive) or removed from (negative) a position (§4.1).
    /// @dev `poolId` is the loan's `poolKeyId`, indexed so an indexer groups by pool without an
    ///      `eth_call` (§4.1 v0.30, FAR-42). It follows the fields §4.1 lists, as R6 of the
    ///      market-id brainstorm places it and `CollectFees` does: topics `tokenId`, `poolId`.
    event LiquidityChanged(uint256 indexed tokenId, PoolId indexed poolId, int256 liqDelta);
    event Borrow(uint256 indexed tokenId, uint256 amount);
    event Repay(uint256 indexed tokenId, uint256 amount);

    /// @notice A collateral position's fees were claimed (§4.1, `poolId` per v0.30).
    /// @dev `amount0`/`amount1` are `to`'s balance change across the claim, not the fees the position
    ///      realised. Anything else reaching `to` while its ETH callback runs is counted as well, a vault
    ///      redeem or a transfer from anyone, so indexers (§13) must not treat these figures as verified
    ///      fee income. A `to` that sends out more than it received during that callback makes the claim
    ///      revert with an arithmetic panic.
    event CollectFees(uint256 indexed tokenId, PoolId indexed poolId, uint256 amount0, uint256 amount1);
    /// @notice A position was liquidated (§8).
    /// @dev `repaid` and `badDebt` are exact ledger figures. `out0`/`out1` are what the
    ///      liquidator received, and on the full branch they are measured, not computed:
    ///      PositionManager pays `to` directly, so they are `to`'s balance change across the
    ///      burn. A contract `to` can distort that — redeem vault shares when the ETH lands, or
    ///      pass the ETH straight on. Only its own figure moves and the ledger never reads it,
    ///      but indexers and keepers (§13) must not treat `out0`/`out1` as the amount seized.
    event Liquidate(
        uint256 indexed tokenId, address indexed liquidator, uint256 repaid, uint256 out0, uint256 out1, uint256 badDebt
    );
    event BadDebtSocialized(uint256 amount);
    event ReservesUpdated(uint256 reserves);
    event ReservesWithdrawn(uint256 amount, address indexed to);

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
    error SpotPriceDeviation(uint256 deviationBps, uint256 maximumDeviationBps);
    error UsdgPriceOutOfBounds(uint256 price);
    error PositionWouldBeUnhealthy(uint256 tokenId, uint256 healthFactor);
    error RemovalExceedsBorrowLimit(uint256 tokenId, uint256 debtUsd, uint256 limitUsd);
    error NativeValueMismatch(uint256 expected, uint256 sent);
    error ZeroLiquidity();
    error LiquidityExceedsPosition(uint256 tokenId, uint128 requested, uint128 available);
    error PermitDoesNotMatchPool();
    error ReserveWithdrawalExceedsAvailable(uint256 amount, uint256 available);

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

        MarketLedger.Layout storage $ = _marketStorage();
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
        _recordMemePosition(tokenId);
        IERC721(address(positionManager)).transferFrom(msg.sender, address(this), tokenId);
        MarketMint.acceptCollateral(_mintEnv(), msg.sender, tokenId);
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
        _recordMemePosition(tokenId);
        nft.transferFrom(depositor, address(this), tokenId);
        MarketMint.acceptCollateral(_mintEnv(), depositor, tokenId);
    }

    /// @notice Mints a new position straight into custody and records it as the caller's
    ///         collateral, in one transaction (§3, §4.1).
    /// @param p The position to mint.
    /// @param permit A Permit2 batch transfer naming this market as spender. It lists the
    ///        pool's ERC-20 currencies in pool order, each for at least its maximum: both for an
    ///        ERC-20 pair, only currency1 for a native-ETH pool.
    /// @param signature The caller's signature over `permit`.
    /// @return tokenId The position minted, now held as the caller's collateral.
    /// @dev Ends in exactly the state `depositCollateral` leaves for the same position: the
    ///      market owns the NFT, the loan is recorded to the caller, `CollateralDeposited` is
    ///      emitted, and `withdrawCollateral` hands it back. Admission is the same function,
    ///      run on the minted id. A position gets no leniency for having been created here —
    ///      if it did, this would be the way into pools the policy itself refuses. A refusal
    ///      reverts everything, so no orphaned position is left here and the caller keeps
    ///      their tokens.
    ///
    ///      **The id is read before minting.** `modifyLiquidities` returns nothing, and
    ///      PositionManager hands the new position `nextTokenId` and then increments it. Read
    ///      afterwards, the id is one past the position just minted: a token that does not
    ///      exist yet and will belong to whoever mints next. Nothing can mint in between,
    ///      because PositionManager stays locked for the whole call.
    ///
    ///      **The caller is the signer.** The permit is spent with `owner = msg.sender`, because
    ///      whoever submits is who the position is recorded to. Accepting any signer would let
    ///      a broadcast permit spend someone else's tokens on a position in the submitter's
    ///      name. That is the difference from `depositCollateralWithPermit`, where the NFT's
    ///      owner is the only possible beneficiary and a relayer costs nobody anything.
    ///
    ///      Each leg brings its maximum and gets the change back. ERC-20 legs are pulled in
    ///      full through the permit; ETH arrives as `msg.value`, which must equal `amount0Max`
    ///      for a native pool and be zero otherwise. A mint that would cost more than either
    ///      maximum reverts inside PositionManager, which is handed the permit's deadline — the
    ///      one the caller signed.
    ///
    ///      **§4.1 says the change comes back through `SWEEP`; for an ERC-20 leg it cannot.**
    ///      `SWEEP` sends PositionManager's own balance, while `SETTLE_PAIR` pays an ERC-20 leg
    ///      straight from this market through Permit2, so that change never leaves the market.
    ///      Both sweeps are still encoded and return the unspent ETH; ERC-20 change is sent back
    ///      by `_returnChange`.
    function mintAndDeposit(
        MintParams calldata p,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant returns (uint256 tokenId) {
        _recordMemePool(p.poolKey);
        return MarketMint.mintAndDeposit(_mintEnv(), _mintParams(p), permit, signature);
    }

    /// @notice Adds liquidity to a position held as the caller's collateral (§4.1).
    /// @param tokenId The position. Only the address it is recorded to may add to it.
    /// @param liquidity Liquidity to add.
    /// @param amount0Max The most currency0 the addition may cost. For a native-ETH pool this is
    ///        also exactly the `msg.value` to send.
    /// @param amount1Max The most currency1 the addition may cost.
    /// @param permit A Permit2 batch transfer naming this market as spender, listing the pool's
    ///        ERC-20 currencies in pool order, each for at least its maximum.
    /// @param signature The caller's signature over `permit`.
    /// @dev **The position's fees are claimed to the caller first** (§4.1 v0.47, decided on PR
    ///      #19). `INCREASE_LIQUIDITY` credits uncollected fees against what the addition costs,
    ///      and a leg whose fees exceed its cost leaves PositionManager owed nothing, which
    ///      `SETTLE` refuses (`DeltaNotNegative`). That is every addition to an out-of-range
    ///      position holding fees on the leg it no longer spends, whatever its size. So the claim
    ///      is made explicitly first — `DECREASE_LIQUIDITY(0)` and a `TAKE` per leg — and the
    ///      addition that follows can only owe. It is the same claim `collectFees` makes, in the
    ///      same transaction, which is why it carries the same protections:
    ///
    ///      **with debt outstanding the position is checked afterwards, not before.** The addition
    ///      pays in and the claim pays out, so the health factor is read once both have happened
    ///      and must be at least 1 (`MarketDebt.requireHealthy`, §7). That check runs §5.2's borrow
    ///      price gates first, exactly as `collectFees` does (v0.40): fees must not leave at a price
    ///      the market refuses to lend against. A position owing nothing runs neither, because
    ///      there is no debt to protect.
    ///
    ///      **The pool must still pass §6.1**, checked before any token moves: it may have been
    ///      frozen, or lost a token or its hook allowlisting, since the position was deposited
    ///      (§6.5), and new capital must not go where the policy itself refuses it. A zero
    ///      `liquidity` is refused too: that is a fee claim, and `collectFees` is the function for
    ///      one.
    ///
    ///      On a meme market the addition records the pool's TWAP observation first, as every
    ///      market transaction touching a meme pool but `liquidate` does (§5.3). It runs inside
    ///      the library, after the checks above, so a refusal names its own reason.
    ///
    ///      **The tokens never touch this market, departing from §4.1's `SETTLE_PAIR`.** Permit2
    ///      delivers the caller's maxima straight to PositionManager, which settles out of its
    ///      own balance and sweeps the rest back to the caller. Pulled here instead, they would
    ///      sit in `totalAssets` while the pool's hook runs, and a hook holding vault shares
    ///      could redeem at that inflated price and have the difference paid out of the
    ///      caller's change (§4.1 v0.26). Nothing is approved and no change is measured here, so
    ///      lenders' cash is out of reach by construction rather than by a balance check.
    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external payable whenNotPaused nonReentrant {
        MarketMint.increaseLiquidity(
            _mintEnv(),
            MarketMint.IncreaseParams({
                tokenId: tokenId, liquidity: liquidity, amount0Max: amount0Max, amount1Max: amount1Max
            }),
            permit,
            signature
        );
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
        _recordMemePosition(tokenId);
        MarketMint.acceptCollateral(_mintEnv(), from, tokenId);
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

        MarketLedger.Layout storage $ = _marketStorage();
        MarketLedger.Loan memory loan = $.loans[tokenId];

        if (loan.owner != msg.sender) revert NotTheDepositor(tokenId, loan.owner);
        // Collateral remains locked until its debt shares have been fully repaid.
        if (loan.debtShares != 0) revert OutstandingDebt(tokenId, loan.debtShares);

        delete $.loans[tokenId];
        emit CollateralWithdrawn(tokenId, msg.sender);

        IERC721(address(positionManager)).safeTransferFrom(address(this), to, tokenId);
    }

    /// @notice Claims every fee a collateral position has earned, to `to` (§4.1).
    /// @param tokenId The position. Only its depositor may claim.
    /// @param to Where both fee legs go, native ETH included. Not the zero address, this market,
    ///        PositionManager, or the `address(1)`/`address(2)` placeholders PositionManager reads as
    ///        its caller and itself (§4.1 v0.43).
    /// @dev **Pausable, unlike `withdrawCollateral`.** With debt outstanding the claim prices the
    ///      position, and §4.1 stops everything that relies on the oracle while the market is
    ///      paused. A frozen or delisted pool does not stop it (§6.5): nothing here asks whether
    ///      the pool still accepts positions, only for its terms.
    ///
    ///      On a meme market the claim records the pool's TWAP observation first, as every market
    ///      transaction touching a meme pool but `liquidate` does (§5.3): the health check prices
    ///      the position through it.
    ///
    ///      The claim runs from `MarketLiquidity`, which documents the recipient rule, the
    ///      post-claim health check and its price gates (§5.2 v0.40), and why nothing is written
    ///      after the first outbound call.
    function collectFees(
        uint256 tokenId,
        address to
    ) external whenNotPaused nonReentrant {
        _recordMemePosition(tokenId);
        MarketLiquidity.collectFees(
            MarketLiquidity.Env({positionManager: positionManager, debt: _debtEnv()}), tokenId, to
        );
    }

    /// @notice Removes part of a collateral position's liquidity, to `to` (§4.1).
    /// @param tokenId The position. Only its depositor may remove from it.
    /// @param liq How much liquidity to remove. Not zero (`collectFees` claims fees alone), not more
    ///        than the position holds, never so much that what stays falls under the pool's minimum
    ///        position value (§6.1), debt or no debt, and with debt outstanding never so much that
    ///        the debt no longer fits the borrow limit of what stays (§4.1 v0.59).
    /// @param min0 The least `currency0` principal the removal must return, or it reverts.
    /// @param min1 The same for `currency1`. PositionManager holds both against the principal only:
    ///        the position's fees are paid out as well, and never count towards either.
    /// @param to Where both legs go, native ETH included. Refused exactly as `collectFees` refuses
    ///        a recipient (§4.1 v0.43).
    /// @dev **Pausable**, like `collectFees`: with debt outstanding the removal prices the position
    ///      (§4.1 pause scope). A frozen or delisted pool does not stop it (§6.5).
    ///
    ///      The removal runs from `MarketLiquidity`, which documents why `to` receives every fee as
    ///      well, the minimum held on what remains, the post-removal borrow limit and its price
    ///      gates (§5.2), the meme observation (§5.3), and why nothing is written after the first
    ///      outbound call.
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liq,
        uint128 min0,
        uint128 min1,
        address to
    ) external whenNotPaused nonReentrant {
        MarketLiquidity.decreaseLiquidity(
            MarketLiquidity.Env({positionManager: positionManager, debt: _debtEnv()}),
            MarketLiquidity.DecreaseParams({
                tokenId: tokenId, liquidity: liq, amount0Min: min0, amount1Min: min1, to: to
            })
        );
    }

    /// @notice Accepts native ETH (§4.1).
    /// @dev Pools whose `currency0` is `address(0)` pay out in ETH, and §8's partial seizure is
    ///      the first path that takes delivery here: `TAKE_PAIR` pays the market, which forwards
    ///      the liquidator's share and returns the borrower's. Both legs leave in the same call,
    ///      so nothing a liquidation brings in is left sitting.
    ///
    ///      ETH that turns up any other way has no accounting, and `rescueUnaccountedEth` is its
    ///      way out: the trapped-asset hole `rescueUnaccountedToken` closes, one asset class
    ///      over (§15 no. 12).
    receive() external payable {}

    /* ---------------------------------- views --------------------------------- */

    /// @notice The collateral tier this market accepts.
    function tier() external view returns (ICollateralPolicy.Tier) {
        return _marketStorage().tier;
    }

    /// @notice The loan recorded against a position, or a zeroed record if there is none.
    function loanOf(
        uint256 tokenId
    ) external view returns (MarketLedger.Loan memory) {
        return _marketStorage().loans[tokenId];
    }

    /// @notice Accrues index-based interest since the last state-changing operation.
    function accrue() public {
        MarketDebt.accrue(_debtEnv());
    }

    /// @notice Borrows USDG against a deposited position, subject to LTV and debt caps.
    function borrow(
        uint256 tokenId,
        uint256 amount,
        address to
    ) external whenNotPaused nonReentrant {
        _recordMemePosition(tokenId);
        MarketDebt.borrow(_debtEnv(), tokenId, amount, to);
    }

    /// @notice Repays debt. Pass `type(uint256).max` to repay the complete outstanding debt.
    function repay(
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant returns (uint256 repaid) {
        return MarketDebt.repay(_debtEnv(), tokenId, amount);
    }

    /// @notice Repays an unhealthy position's debt on its behalf and seizes collateral for it.
    /// @param tokenId The position to liquidate.
    /// @param repayAmount USDG the caller offers against the debt. Cut down by the close
    ///        factor (§6.2), and again by what the position can actually pay for.
    /// @param minOut0 Least currency0 the caller accepts, measured on what **they** receive.
    /// @param minOut1 Least currency1 the caller accepts, on the same basis.
    /// @param to Where the seized tokens go. The same addresses are refused as for `collectFees`,
    ///        on both branches (§4.1 v0.43).
    /// @return repaid USDG actually taken off the debt, the borrower's own fees included.
    /// @return out0 currency0 the liquidator received, any fee leg it bought included. On the
    ///         full branch a contract `to` can distort it; see `Liquidate`.
    /// @return out1 currency1 the liquidator received, on the same basis.
    /// @return badDebt Debt the position could not cover, absorbed under §9.
    /// @dev One function with two branches, as §8 steps 4 and 5 describe them, because the
    ///      branch is not a mode the caller picks: it is whatever is left when the repay cap
    ///      has been applied. A seizure that reaches past everything the position holds takes
    ///      the position whole; anything smaller takes a slice.
    ///
    ///      **Nothing on this path touches the borrow price gate of §5.2, and that is the
    ///      point.** Collateral is valued through `valueForLiquidation`, and the debt side is
    ///      priced with `priceForLiquidation` too, so a USDG outside [0,97; 1,03] or a pool 2%
    ///      off the oracle both stop borrowing and leave liquidation running. Revert Lend blocks
    ///      both; Farmenta blocks only borrowing, so there is never a window where an underwater
    ///      position cannot be cleared (§5.2).
    ///
    ///      **The partial branch routes the payout through this contract, and must keep
    ///      doing so.** `_decrease` realises the position's *entire* fee balance no matter how
    ///      little liquidity it pulls, so a `TAKE_PAIR` addressed straight to the liquidator
    ///      hands them every fee in the position for the price of a one-wei repay — the v0.2
    ///      gap, closed in v0.3. The market takes delivery, forwards the principal slice plus
    ///      fees worth `feeCredit`, and keeps the rest for the borrower. It is also why this
    ///      cannot reuse `decreaseLiquidity` (FAR-8), which pays its caller directly.
    ///
    ///      **The work itself runs from `MarketLiquidation`, by `delegatecall`.** It is the
    ///      market's storage, the market's address and the liquidator's `msg.sender` either
    ///      way; what changes is where the code sits, which is the rule for everything this
    ///      contract does (§4.1 v0.33): logic in a linked library, a wrapper here. What stays
    ///      here is what has to be visible from outside: the pause, the reentrancy guard, the
    ///      accrual, and every event.
    ///
    ///      **No `record` up here, unlike every other meme path.** The library records the
    ///      observation after the seizure, so the gate prices the recorder as it stands and
    ///      §5.3's stale mode can actually be reached (§5.3 v0.52, FAR-49).
    function liquidate(
        uint256 tokenId,
        uint256 repayAmount,
        uint128 minOut0,
        uint128 minOut1,
        address to
    ) external whenNotPaused nonReentrant returns (uint256 repaid, uint256 out0, uint256 out1, uint256 badDebt) {
        accrue();

        MarketLiquidation.Outcome memory outcome = MarketLiquidation.execute(
            MarketLiquidation.Env({
                positionManager: positionManager, policy: policy, valuer: valuer, oracle: oracle, asset: asset()
            }),
            MarketLiquidation.Request({
                tokenId: tokenId, repayAmount: repayAmount, minOut0: minOut0, minOut1: minOut1, to: to
            })
        );

        (repaid, out0, out1, badDebt) = (outcome.repaid, outcome.out0, outcome.out1, outcome.badDebt);
        emit ReservesUpdated(_marketStorage().reserves);
        if (outcome.socialized != 0) emit BadDebtSocialized(outcome.socialized);
        emit Liquidate(tokenId, msg.sender, repaid, out0, out1, badDebt);
    }

    function debtOf(
        uint256 tokenId
    ) public view returns (uint256) {
        MarketLedger.Layout storage $ = _marketStorage();
        return DebtMath.debtOf($.loans[tokenId].debtShares, $.borrowIndex);
    }

    function totalBorrows() external view returns (uint256) {
        return _marketStorage().totalBorrows;
    }

    function totalBorrowShares() external view returns (uint256) {
        return _marketStorage().totalBorrowShares;
    }

    function borrowIndex() external view returns (uint256) {
        return _marketStorage().borrowIndex;
    }

    function reserves() external view returns (uint256) {
        return _marketStorage().reserves;
    }

    /// @notice Cumulative reserve revenue withdrawn by the owner.
    function totalReservesWithdrawn() external view returns (uint256) {
        return _marketStorage().totalReservesWithdrawn;
    }

    /// @notice Reserve floor rate enforced by `withdrawReserves`, in basis points.
    function reserveFloorBps() external view returns (uint16) {
        return _marketStorage().reserveFloorBps;
    }

    function _withdrawableReserves(
        uint256 cash
    ) private view returns (uint256) {
        MarketLedger.Layout storage $ = _marketStorage();
        uint256 floor = _reserveFloor(cash);
        if ($.reserves <= floor) return 0;
        return Math.min($.reserves - floor, cash);
    }

    function _reserveFloor(
        uint256 cash
    ) private view returns (uint256) {
        MarketLedger.Layout storage $ = _marketStorage();
        return (cash + $.totalBorrows - $.reserves) * $.reserveFloorBps / BPS;
    }

    function poolDebt(
        PoolId poolId
    ) external view returns (uint256) {
        return _poolDebt(poolId);
    }

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view override returns (uint256) {
        MarketLedger.Layout storage $ = _marketStorage();
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

    /// @notice Transfers reserve revenue above the tier's lender-protection floor.
    /// @param amount USDG amount to transfer.
    /// @param to Recipient of the reserve withdrawal.
    /// @dev The floor is calculated before reserve accounting and cash are reduced, so this
    ///      transfer leaves `totalAssets` and the lender buffer unchanged (§7).
    function withdrawReserves(
        uint256 amount,
        address to
    ) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        accrue();

        uint256 available = _withdrawableReserves(IERC20(asset()).balanceOf(address(this)));
        if (amount > available) revert ReserveWithdrawalExceedsAvailable(amount, available);

        MarketLedger.Layout storage $ = _marketStorage();
        $.reserves -= amount;
        $.totalReservesWithdrawn += amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit ReservesUpdated($.reserves);
        emit ReservesWithdrawn(amount, to);
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

    /// @notice Recovers native ETH that reached this contract outside any payout (§15 no. 12).
    /// @param to Where to send it.
    /// @dev Sweeps the whole balance, which is sound only because no ETH here is owed to anyone
    ///      between transactions. Every path that takes delivery of ETH pays all of it out
    ///      before its own call returns: liquidation forwards the liquidator's and the
    ///      borrower's legs, and `mintAndDeposit` and `increaseLiquidity` return change through
    ///      `SWEEP` straight from PositionManager. `collectFees` and `decreaseLiquidity` never take
    ///      delivery at all: each `TAKE` pays its recipient, and `address(1)`, which would route the
    ///      ETH here, is refused.
    ///      What is left was sent by mistake or by force, and taking it takes
    ///      nothing a lender or a borrower is owed.
    ///
    ///      `nonReentrant` keeps it out of the one place that premise does not hold: inside a
    ///      liquidation, where the balance briefly belongs to the payout. A future path that
    ///      holds ETH across transactions has to revisit this function.
    function rescueUnaccountedEth(
        address to
    ) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);

        uint256 amount = address(this).balance;
        emit UnaccountedEthRescued(amount, to);
        Currency.wrap(address(0)).transfer(to, amount);
    }

    /* -------------------------------- internals ------------------------------- */

    function _poolDebt(
        PoolId poolId
    ) private view returns (uint256) {
        MarketLedger.Layout storage $ = _marketStorage();
        return DebtMath.debtOf($.poolDebtShares[poolId], $.borrowIndex);
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
    ///
    ///      It also refuses re-entry. `mintAndDeposit` measures its change by balance, so a vault
    ///      deposit made from inside a mint — a pool hook calling back — would be paid out as the
    ///      minter's change while the hook kept the shares. Nothing legitimate deposits from
    ///      inside another market call.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused nonReentrant {
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

    /// @dev The layout itself lives in `MarketLedger`, so `MarketLiquidation` can write the
    ///      same slots from its own compilation unit without a second copy of the struct.
    function _marketStorage() private pure returns (MarketLedger.Layout storage $) {
        return MarketLedger.layout();
    }

    function _debtEnv() private view returns (MarketDebt.Env memory) {
        return MarketDebt.Env({
            asset: IERC20(asset()), policy: policy, valuer: valuer, oracle: oracle, interestRateModel: interestRateModel
        });
    }

    function _mintEnv() private view returns (MarketMint.Env memory) {
        return MarketMint.Env({positionManager: positionManager, policy: policy, valuer: valuer, debt: _debtEnv()});
    }

    /// @dev Blue-chip calls stop before the external oracle call, so their existing price path
    ///      neither records observations nor pays the recorder's gas.
    function _recordMemePosition(
        uint256 tokenId
    ) private {
        if (_marketStorage().tier != ICollateralPolicy.Tier.MEME) return;
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        oracle.record(key);
    }

    function _recordMemePool(
        PoolKey memory key
    ) private {
        if (_marketStorage().tier == ICollateralPolicy.Tier.MEME) oracle.record(key);
    }

    function _mintParams(
        MintParams calldata p
    ) private pure returns (MarketMint.Params memory) {
        return MarketMint.Params({
            poolKey: p.poolKey,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: p.liquidity,
            amount0Max: p.amount0Max,
            amount1Max: p.amount1Max,
            hookData: p.hookData
        });
    }
}
