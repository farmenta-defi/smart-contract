// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";

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

    /// @notice ETH/USDG, dynamic fee, tickSpacing 60, with `HOOK_ETH_USDG_TS60`.
    PoolId internal constant POOL_ETH_USDG_TS60 =
        PoolId.wrap(0x30dac7167c36242d1bacfd30561d444cf014529ee55978991d03e4ee178e725a);

    /// @notice ETH/USDG, no hook, fee 500 (0.05%), tickSpacing 10.
    PoolId internal constant POOL_ETH_USDG_PLAIN_TS10 =
        PoolId.wrap(0x387bf619da4d3fb62bb276482693dba1b9b3520f573cabdfe033384a24125982);

    /// @notice A pools.trade/Doppler pool initialized before the pinned fork block.
    /// @dev This is FIG/BALLS, not a USDG-quoted pool, so it is a recorder-only fixture.
    ///      FAR-16 must mint its own USDG-quoted pool on the fork. Its complete key comes from
    ///      PoolManager's Initialize event at block 54,190,095; keeping the key (not merely
    ///      its id) lets recorder tests exercise `record` too.
    PoolId internal constant POOL_MEME_DOPPLER =
        PoolId.wrap(0xc6451046bf06c20295032cf6e05e85bb1ca35fd7aebaf30c59c33350fe3c776e);

    function memeDopplerKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(0x41F4267525a8AFf329540eF24fD83d9044758B33),
            currency1: Currency.wrap(0x7384d1F183526d83aad28bA5A5eD6dceeA211E18),
            fee: 0x800000,
            tickSpacing: 8,
            hooks: IHooks(HOOK_DOPPLER)
        });
    }

    /// @notice The five initialized pools used to measure the recorder batch on the pinned fork.
    /// @dev Keep the keys and their expected ids together so an incorrect fixture fails before
    ///      `recordBatch` can surface the unhelpful generic `TwapUnavailable` error.
    function liveRecorderPoolKeys() internal pure returns (PoolKey[] memory keys) {
        keys = new PoolKey[](5);
        keys[0] = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.NATIVE),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: 0x800000,
            tickSpacing: 1,
            hooks: IHooks(HOOK_ETH_USDG_DYN)
        });
        keys[1] = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.NATIVE),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: 460,
            tickSpacing: 9,
            hooks: IHooks(address(0))
        });
        keys[2] = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.WETH),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: 200,
            tickSpacing: 4,
            hooks: IHooks(address(0))
        });
        keys[3] = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.NATIVE),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ETH_USDG_TS60)
        });
        keys[4] = PoolKey({
            currency0: Currency.wrap(RobinhoodChain.NATIVE),
            currency1: Currency.wrap(RobinhoodChain.USDG),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
    }

    function liveRecorderPoolIds() internal pure returns (PoolId[] memory ids) {
        ids = new PoolId[](5);
        ids[0] = POOL_ETH_USDG_DYN;
        ids[1] = POOL_ETH_USDG_PLAIN;
        ids[2] = POOL_WETH_USDG_PLAIN;
        ids[3] = POOL_ETH_USDG_TS60;
        ids[4] = POOL_ETH_USDG_PLAIN_TS10;
    }

    /* ---------------------------------- Hooks --------------------------------- */
    /* Permission bits live in the low 14 bits of the address itself.             */
    /* CollateralPolicy rejects bit 9 (beforeRemoveLiquidity), bit 8              */
    /* (afterRemoveLiquidity), bit 1 (afterAddLiquidityReturnsDelta, FAR-47) and  */
    /* bit 0 (afterRemoveLiquidityReturnsDelta): mask 0x303. See ARCHITECTURE.md  */
    /* §6.1.                                                                      */

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

    /* ----------------------------- Real positions ----------------------------- */
    /* Live positions owned by third parties, verified at ForkTest.FORK_BLOCK.     */
    /* Found by scanning PoolManager `ModifyLiquidity` logs (see                   */
    /* script/DiscoverPositions.s.sol) — PositionManager has no ERC721Enumerable,  */
    /* and sampling tokenIds is hopeless: launchpad mints outnumber blue-chip      */
    /* positions by orders of magnitude on this chain.                             */
    /*                                                                            */
    /* `PositionFixturesForkTest` asserts each one still has the shape described   */
    /* here, so a position that gets closed upstream fails loudly instead of       */
    /* silently weakening a test.                                                  */
    /*                                                                            */
    /* No real *below-range* position survives at this block — LPs close them      */
    /* rather than hold a fully one-sided bag. That case, along with single-tick    */
    /* ranges and wei-scale liquidity, is covered by positions minted inside the    */
    /* fork: see test/base/PositionMinter.sol and test/fork/MintedPositions.t.sol.  */

    /// @notice ETH/USDG dyn-fee pool, in range, both fee sides accrued.
    /// @dev The richest fixture: native ETH as currency0, a live hook, a dynamic fee, and
    ///      tickSpacing 1. Worth ~$382 with ~$11 of uncollected fees (2.9% of principal,
    ///      under the 10% cap in §6.2).
    uint256 internal constant POS_ETH_USDG_DYN_IN_RANGE = 913_889;

    /// @notice ETH/USDG plain pool, in range, both fee sides accrued.
    uint256 internal constant POS_ETH_USDG_IN_RANGE = 1_768_881;

    /// @notice ETH/USDG plain pool, **above** range: 100% USDG, and fees freshly collected
    ///         so both fee sides are zero.
    /// @dev Two edge cases in one — the safe out-of-range direction (§6.4) and a position
    ///      whose fee growth delta is exactly zero.
    uint256 internal constant POS_ETH_USDG_ABOVE_RANGE = 1_621_020;

    /// @notice WETH/USDG, wide range (~±17%), in range.
    /// @dev Both currencies are ERC-20 here, unlike the native-ETH pools above.
    uint256 internal constant POS_WETH_USDG_WIDE_IN_RANGE = 999_597;

    /// @notice WETH/USDG, above range: 100% USDG, with fees still uncollected.
    uint256 internal constant POS_WETH_USDG_ABOVE_RANGE = 1_765_960;
}
