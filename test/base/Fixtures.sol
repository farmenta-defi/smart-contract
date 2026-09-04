// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Fixtures
/// @notice Real Robinhood Chain pools and hooks used as test fixtures.
/// @dev Pool ids come from ARCHITECTURE.md §18; hook addresses and their permission bits
///      from §6.1. These describe live third-party state, so they are only meaningful at
///      a pinned fork block — see `ForkTest.FORK_BLOCK`.
library Fixtures {
    /* --------------------------- Blue-chip pools ------------------------------ */

    /// @notice Largest ETH/USDG pool: dynamic fee, tickSpacing 1, hook `HOOK_ETH_USDG_DYN`.
    /// @dev Exercises the auto path of `CollateralPolicy`: the hook is swap-only, so it
    ///      cannot interfere with removing liquidity.
    PoolId internal constant POOL_ETH_USDG_DYN =
        PoolId.wrap(0x80399a859416860c92785ff7f994e67ecbcda12d3f0adb75e0c2466b9bfacf30);

    /// @notice ETH/USDG, no hook, fee 460 (0.046%). ~15x less liquidity than the dyn-fee pool.
    PoolId internal constant POOL_ETH_USDG_PLAIN =
        PoolId.wrap(0x54f7883914619af9105355bf83ed678bcf9f63560218ac61c9963b9503d0ba32);

    /// @notice WETH/USDG, no hook, fee 200 (0.02%). Both currencies are ERC-20 here,
    ///         unlike the pools above where currency0 is native ETH.
    PoolId internal constant POOL_WETH_USDG_PLAIN =
        PoolId.wrap(0x84bd4e2d8be11aeb0afc1195b38f587b61e90068548f1063fdbe448fb8cad0b6);

    /* ---------------------------------- Hooks --------------------------------- */
    /* Permission bits live in the low 14 bits of the address itself.             */
    /* CollateralPolicy rejects bit 9 (beforeRemoveLiquidity), bit 8              */
    /* (afterRemoveLiquidity) and bit 0 (afterRemoveLiquidityReturnsDelta):       */
    /* mask 0x301. See ARCHITECTURE.md §6.1.                                      */

    /// @notice Hook on the largest ETH/USDG pool: `beforeSwap` only → auto path.
    /// @dev Source not verified on Blockscout (§15 item 2); it passes mechanically.
    address internal constant HOOK_ETH_USDG_DYN = 0x78257a554194C3ba10a59357B500788934F34080;

    /// @notice Hook on the ETH/USDG tickSpacing-60 pool: `beforeSwap` only → auto path.
    address internal constant HOOK_ETH_USDG_TS60 = 0x42554Fa546995A393D19B3880D3a4C6709298080;

    /// @notice SoloHook: swap-only with return delta → auto path.
    address internal constant HOOK_SOLO = 0x06d531e6dC53eC28B6C1f5af206Fc2806E9400CC;

    /// @notice pools.trade InitializerHook: `beforeInitialize` only → auto path.
    address internal constant HOOK_POOLS_TRADE_INITIALIZER = 0xD462a559337859369EF271814851A18F496ba000;

    /// @notice DopplerHookInitializer: has `afterRemoveLiquidity` → manual review path.
    address internal constant HOOK_DOPPLER = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;

    /// @notice CashCatHookV2: has `beforeRemoveLiquidity` → manual review path.
    address internal constant HOOK_CASHCAT_V2 = 0x75A54357D9C78a2Db19004a5FDc76c50F9242AEC;
}
