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
///      Constants only — nothing here is deployed, so importing this costs no bytecode.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;

    /* ------------------------------- Uniswap v4 ------------------------------- */

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    /// @notice Primary router: 11.3M txs, the one the Uniswap app uses.
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    /// @notice Newer deployment, 43.7k txs. Both are verified `UniversalRouter`.
    address internal constant UNIVERSAL_ROUTER_ALT = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /* ------------------------------ Third party ------------------------------- */

    /// @notice Flash loan source for `LiquidatorHelper` (ARCHITECTURE §4.7).
    address internal constant MORPHO_BLUE = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;

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
    /// @notice Not used yet; listed in §18 for completeness.
    address internal constant CHAINLINK_BTC_USD = 0xa2c5184bF03d373Dc9dE4876eb4Bce595B460251;
    /// @notice Not used yet; listed in §18 for completeness.
    address internal constant CHAINLINK_USDC_USD = 0x9e6f4605992a899eE2999999F3Ec80C41F452546;

    address internal constant PYTH = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

    /// @notice Chainlink's L2 Sequencer Uptime Feed does **not** exist on this chain
    ///         (checked 2026-08-26 against the official directory, 57 feeds). ARCHITECTURE
    ///         §5.2/§15.1: the MVP mitigation is the owner pausing when the sequencer is down.
    address internal constant SEQUENCER_UPTIME_FEED = address(0);
}
