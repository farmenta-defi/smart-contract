// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {ICollateralPolicy} from "./interfaces/ICollateralPolicy.sol";
import {IPositionValuer} from "./interfaces/IPositionValuer.sol";

/// @title FarmentaMarket
/// @notice Custodies Uniswap v4 LP position NFTs and lends USDG against them
///         (ARCHITECTURE §4.1). One implementation, two proxies: Blue-chip and Meme.
/// @dev **This contract currently implements the custody half only.** Collateral can be
///      deposited and withdrawn; the debt ledger, interest accrual, borrowing, repayment and
///      liquidation land in Phase 1 (§16). The ERC-4626 side is inherited and functional, but
///      earns nothing yet: with no borrows, `totalAssets` is simply the USDG this contract
///      holds. §7 overrides it once `totalBorrows` and `reserves` exist.
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
    }

    /// @custom:storage-location erc7201:farmenta.storage.Market
    struct MarketStorage {
        /// @dev Which tier this proxy accepts. Storage rather than an immutable because one
        ///      implementation backs both markets, and they differ only here.
        ICollateralPolicy.Tier tier;
        mapping(uint256 tokenId => Loan) loans;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("farmenta.storage.Market")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKET_STORAGE_LOCATION =
        0x7264a1ba9a51633de6d083d092b5001ae1c4b527f9b0578321c709cd9ac3df00;

    /// @notice Decimal offset on the vault's shares, against inflation attacks (§7).
    uint8 private constant DECIMALS_OFFSET = 3;

    /// @notice The Uniswap position NFT this market custodies.
    /// @dev Immutable in the implementation and changed by upgrading, like every other
    ///      dependency here (§4.1): each extra proxy would double the storage-collision
    ///      surface without adding a capability.
    IPositionManager public immutable positionManager;

    /// @notice Decides which pools may back a loan, and on what terms (§4.5, §6).
    ICollateralPolicy public immutable policy;

    /// @notice Values a position at oracle prices (§4.2, §5.1).
    IPositionValuer public immutable valuer;

    /// @notice A position was taken into custody as collateral.
    event CollateralDeposited(uint256 indexed tokenId, address indexed owner);

    error ZeroAddress();
    error TierNotSet();
    error NotThePositionManager(address caller);
    error PositionAlreadyHeld(uint256 tokenId);
    error PositionIsEmpty(uint256 tokenId);
    error PositionBelowMinimum(uint256 principalUsd, uint256 minimumUsd);

    /// @param positionManager_ Uniswap v4 PositionManager, the only NFT this market takes.
    /// @param policy_ Collateral policy the market defers listing decisions to.
    /// @param valuer_ Position valuer the market prices collateral with.
    /// @dev Constructor only sets immutables and locks the implementation. All proxy state is
    ///      established in `initialize`.
    constructor(
        IPositionManager positionManager_,
        ICollateralPolicy policy_,
        IPositionValuer valuer_
    ) {
        if (address(positionManager_) == address(0) || address(policy_) == address(0) || address(valuer_) == address(0))
        {
            revert ZeroAddress();
        }

        positionManager = positionManager_;
        policy = policy_;
        valuer = valuer_;

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

        _marketStorage().tier = tier_;
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
        if ($.loans[tokenId].owner != address(0)) revert PositionAlreadyHeld(tokenId);

        // No existence check: both intake paths reach here holding the NFT, and
        // `PositionManager` clears a position's info in the same call that burns its token.
        // Owning it therefore implies it exists. Were that ever untrue, the zeroed key names
        // a pool that cannot be listed anyway, since neither of its currencies is USDG.
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);

        ICollateralPolicy.Terms memory terms = policy.checkPool(key, $.tier);

        IPositionValuer.Valuation memory valuation = valuer.value(tokenId);
        if (valuation.liquidity == 0) revert PositionIsEmpty(tokenId);
        if (valuation.principalUsd < terms.minPositionUsd) {
            revert PositionBelowMinimum(valuation.principalUsd, terms.minPositionUsd);
        }

        $.loans[tokenId].owner = depositor;
        emit CollateralDeposited(tokenId, depositor);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Owner-only, no timelock. See the trust note on this contract.
    function _authorizeUpgrade(
        address
    ) internal override onlyOwner {}

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
