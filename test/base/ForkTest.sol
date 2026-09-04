// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {RobinhoodChain} from "../../src/constants/RobinhoodChain.sol";

/// @title ForkTest
/// @notice Base for every test that reads live Uniswap v4 state on Robinhood Chain.
/// @dev The fork is pinned to a block so results stay reproducible: the public RPC keeps
///      only ~10–25 minutes of state history, so an archive endpoint is required. Set
///      `ROBINHOOD_RPC_URL` (see `.env.example`); the `robinhood` alias resolves it via
///      `[rpc_endpoints]` in foundry.toml.
///
///      Tests inheriting this live under `test/fork/` and are excluded from the fast CI
///      lane, which runs without network access.
abstract contract ForkTest is Test {
    /// @notice Pinned fork block. Raising it invalidates any hard-coded expectation about
    ///         live third-party positions, so re-run the fixture checks when you change it.
    uint256 internal constant FORK_BLOCK = 54_200_000;

    /// @notice `PositionManager.nextTokenId()` at `FORK_BLOCK` — used to assert the fork
    ///         really is where we think it is.
    /// @dev Deliberately a state fact rather than `block.number`. Robinhood Chain is an
    ///      Arbitrum Orbit chain, where `block.number` reports the **L1** block, not the L2
    ///      block passed to `createSelectFork` — and Foundry versions disagree about
    ///      surfacing that (a nightly returned the L2 number locally while CI's stable
    ///      returned the L1 one). Nothing in this repo may use `block.number` for timing;
    ///      interest accrual and TWAP windows are defined on `block.timestamp` (§5.3, §7).
    uint256 internal constant FORK_NEXT_TOKEN_ID = 1_773_489;

    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    IStateView internal stateView;

    function setUp() public virtual {
        vm.createSelectFork("robinhood", FORK_BLOCK);

        poolManager = IPoolManager(RobinhoodChain.POOL_MANAGER);
        positionManager = IPositionManager(payable(RobinhoodChain.POSITION_MANAGER));
        stateView = IStateView(RobinhoodChain.STATE_VIEW);

        vm.label(RobinhoodChain.POOL_MANAGER, "PoolManager");
        vm.label(RobinhoodChain.POSITION_MANAGER, "PositionManager");
        vm.label(RobinhoodChain.STATE_VIEW, "StateView");
        vm.label(RobinhoodChain.USDG, "USDG");
        vm.label(RobinhoodChain.WETH, "WETH");
        vm.label(RobinhoodChain.PERMIT2, "Permit2");
    }
}
