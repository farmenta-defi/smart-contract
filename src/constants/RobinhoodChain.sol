// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RobinhoodChain
/// @notice Deployed contract addresses on Robinhood Chain mainnet (chain id 4663).
/// @dev Transcribed from `farmenta-defi/docs` → ARCHITECTURE.md §18, which is the single
///      source of truth for addresses. Never reconstruct an address from a truncated form:
///      on 2026-08-26 the frontend carried an ETH/USD address whose middle was wrong yet
///      whose truncation matched. `test/fork/Addresses.t.sol` asks each address on-chain
///      what it is; `make addresses` runs it.
///
///      Only addresses something actually uses live here. The V4Quoter, UniversalRouter,
///      and Morpho Blue entries are used by the liquidator periphery; the BTC/USD and
///      USDC/USD feeds remain intentionally omitted because they are not protocol dependencies.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;

    /* ------------------------------- Uniswap v4 ------------------------------- */

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    /// @notice Uniswap v4 quoter used by the off-chain liquidator route builder.
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    /// @notice Uniswap's primary UniversalRouter deployment on Robinhood Chain.
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    /// @notice Morpho Blue deployment used as the USDG flash-loan source.
    address internal constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /* --------------------------------- Tokens --------------------------------- */

    /// @notice Paxos USDG — the borrow asset. 6 decimals, not 18.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @notice Native ETH is `address(0)` inside a v4 `PoolKey`, not WETH.
    address internal constant NATIVE = address(0);

    uint8 internal constant USDG_DECIMALS = 6;
    uint8 internal constant WETH_DECIMALS = 18;

    /* -------------------------------- Oracles --------------------------------- */

    address internal constant CHAINLINK_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address internal constant CHAINLINK_USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    /// @notice Chainlink's L2 Sequencer Uptime Feed does **not** exist on this chain
    ///         (checked 2026-08-26 against the official directory, 57 feeds). ARCHITECTURE
    ///         §5.2/§15.1: the MVP mitigation is the owner pausing when the sequencer is down.
    address internal constant SEQUENCER_UPTIME_FEED = address(0);
}
